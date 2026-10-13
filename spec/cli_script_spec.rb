# frozen_string_literal: true

require 'stringio'
require 'sandbox'
require 'cli/sandbox'

# Offline regression suite for the CLI script runner (lib/cli/context/script.rb).
#
# Boundary under test: the REAL command handlers registered by the real context
# file, driven at the real dispatch boundary (Sandbox::Command#exec). The file
# is loaded exactly once against a real Sandbox gem context registry bound to
# an in-memory shell; no real autohack main, no network, no private CLI
# configs and no temporary files are involved.
#
# Isolation mechanism: File.file?, Kernel#load and Thread.new are example-scoped
# stubs. Canned script classes (top-level names exactly matching each typed
# script's capitalize form) are defined by the load stub. Each canned main and
# finish creates its own blocking Queue gate and surfaces it through the
# recorded events stream, so the test releases every stage in the exact event
# order and no example ever sleeps. Every spawned thread is joined (or
# deadline-killed) in teardown. Constants the context file defines (and the
# harness constants) are removed or restored in the suite and example teardown
# so the rest of the full suite (CLI batch, Hackers modules) keeps its exact
# fixture set.
RSpec.describe 'CLI script runner offline job lifecycle (autohack admission guard)' do
  CLISCRIPT_RUNSPEC = {} # harness-owned mutable state; removed in the suite teardown

  before(:all) do
    @prior_base_dir = Object.const_defined?(:BASE_DIR, false) ? [true, Object.const_get(:BASE_DIR, false)] : nil
    @prior_shell = Object.const_defined?(:SHELL, false) ? [true, Object.const_get(:SHELL, false)] : nil
    @prior_game = Object.const_defined?(:GAME, false) ? [true, Object.const_get(:GAME, false)] : nil
    @prior_context_script = Object.const_defined?(:CONTEXT_SCRIPT, false) ? [true, Object.const_get(:CONTEXT_SCRIPT, false)] : nil

    CLISCRIPT_RUNSPEC[:output] = StringIO.new
    @prior_report_on_exception = Thread.report_on_exception
    Thread.report_on_exception = false # disable uncaught SyntaxError/kill unwinds from suite noise
    Object.const_set(:BASE_DIR, '/ta-hackers-spec-synthetic')
    Object.const_set(:GAME, Object.new) # inert: Sandbox::Script only stores it
    Object.const_set(:SHELL, Sandbox::Shell.new(StringIO.new, CLISCRIPT_RUNSPEC[:output]))
    Object.const_set(:CONTEXT_SCRIPT, SHELL.add_context(:script, description: 'Scripts'))
    require_relative '../lib/cli/context/script' # the REAL production file, loaded once

    @run_cmd = Object.const_get(:CONTEXT_SCRIPT_RUN)
    @kill_cmd = Object.const_get(:CONTEXT_SCRIPT_KILL)
    @admin_cmd = Object.const_get(:CONTEXT_SCRIPT_ADMIN)
    @jobs_cmd = CONTEXT_SCRIPT.commands.detect { |command| command.name == :jobs }
  end

  def canned_file(name)
    File.join(SCRIPT_DIR, "#{name}#{SCRIPT_EXT}")
  end

  def reset_control!
    CLISCRIPT_RUNSPEC[:events] = Queue.new
    CLISCRIPT_RUNSPEC[:loads] = []
    CLISCRIPT_RUNSPEC[:threads] = []
    CLISCRIPT_RUNSPEC[:loading_actions] = [] # default: define the canned class
    CLISCRIPT_RUNSPEC[:loaders] = {
      File.expand_path(canned_file('autohack')) => ['Autohack'],
      File.expand_path(canned_file('faketool')) => ['Faketool']
    }
    CLISCRIPT_RUNSPEC[:files_ok] = [
      File.expand_path(canned_file('autohack')),
      File.expand_path(canned_file('faketool'))
    ]
    # fresh capture buffer per example; the shell binds it by ivar swap
    CLISCRIPT_RUNSPEC[:output] = StringIO.new
    SHELL.instance_variable_set(:@output, CLISCRIPT_RUNSPEC[:output])
  end

  # Defines one canned script class whose constant name matches script.capitalize.
  # main: records, blocks on its own gate until the test releases it, records
  # completion. finish: records, blocks on its own gate until released.
  def define_canned_class!(name)
    events = CLISCRIPT_RUNSPEC[:events]
    Object.const_set(
      name.to_sym,
      Class.new(Sandbox::Script) do
        define_method(:initialize) do |game, shell, logger, args|
          super(game, shell, logger, args)
          events.push([:new, name])
        end

        define_method(:main) do
          gate = Queue.new
          events.push([:main, name, gate])
          gate.pop
          events.push([:main_done, name, nil])
        end

        define_method(:finish) do
          gate = Queue.new
          events.push([:finish, name, gate])
          gate.pop
        end
      end
    )
  end

  def next_event(timeout: 5)
    CLISCRIPT_RUNSPEC[:events].pop(timeout: timeout)
  rescue ThreadError
    raise "spec event timeout: no event arrived within #{timeout}s"
  end

  def next_event!(kind)
    skipped_new = 0
    loop do
      event = next_event
      if event.is_a?(Array) && event[0] == :new && kind != :new
        skipped_new += 1
        next
      end
      if !event.is_a?(Array) || event[0] != kind
        raise "spec expected #{kind.inspect}, got #{event.inspect} (skipped #{skipped_new} constructor events)"
      end

      return event
    end
  end

  def expect_no_event!
    popped = begin
      CLISCRIPT_RUNSPEC[:events].pop(timeout: 0.3)
    rescue ThreadError
      nil
    end
    raise "spec expected no pending events, got #{popped.inspect}" unless popped.nil?
  end

  # Releases the main gate and returns when the worker has reached its finish
  # gate: [main_done_event, finish_event]. The caller releases finish_event[2]
  # itself so rows can delay completion while asserting intermediate state.
  def release_main_and_hold_finish!(main_event)
    main_event[2] << :go
    main_done = next_event!(:main_done)
    finish_event = next_event!(:finish)
    [main_done, finish_event]
  end

  # Drains events until `count` finish gates have been released; holds other
  # event kinds and returns them in arrival order (order across concurrent
  # worker threads is intentionally not asserted here).
  def release_finish_gates!(count)
    held = []
    released = 0
    while released < count
      event = next_event
      if event.is_a?(Array) && event[0] == :finish
        event[2] << :go
        released += 1
      else
        held << event
      end
    end
    [held, released]
  end

  def wait_thread(thread, timeout: 5)
    thread.join(timeout)
    raise 'spec worker thread is still alive after the release' if thread.alive?

    nil
  end

  def with_jobs_lock
    if Object.const_defined?(:SCRIPT_JOBS_MUTEX, false)
      SCRIPT_JOBS_MUTEX.synchronize { yield }
    else
      yield
    end
  end

  def jobs_snapshot
    with_jobs_lock do
      SCRIPT_JOBS.map { |id, record| { id: id, script: record[:script], thread: record[:thread], instance: record[:instance] } }
    end
  end

  def output_text
    CLISCRIPT_RUNSPEC[:output].string
  end

  def run_command!(tokens)
    @run_cmd.exec(tokens)
  end

  before(:each) do
    @prior_autohack = Object.const_defined?(:Autohack, false) ? Object.const_get(:Autohack, false) : nil
    Object.send(:remove_const, :Autohack) if @prior_autohack
    Object.send(:remove_const, :Faketool) if Object.const_defined?(:Faketool, false)

    with_jobs_lock { SCRIPT_JOBS.clear }
    SCRIPT_VARS[:job_counter] = 0
    reset_control!

    @original_file_q = File.method(:file?)
    allow(File).to receive(:file?) do |path|
      CLISCRIPT_RUNSPEC[:files_ok].include?(File.expand_path(path)) || @original_file_q.call(path)
    end

    allow_any_instance_of(Object).to receive(:load) do |_instance, path|
      CLISCRIPT_RUNSPEC[:loads] << path
      action = CLISCRIPT_RUNSPEC[:loading_actions].shift || :define
      case action
      when :raise_syntax
        raise SyntaxError, 'canned syntax failure stub'
      when :no_define
        nil # the load succeeds but defines nothing: handler raises Class not found
      else
        loader = CLISCRIPT_RUNSPEC[:loaders][File.expand_path(path)]
        raise "spec loader missing for #{path}" if loader.nil?

        define_canned_class!(loader[0])
      end
    end

    allow(Thread).to receive(:new).and_wrap_original do |method, *args, &blk|
      thread = method.call(*args, &blk)
      CLISCRIPT_RUNSPEC[:threads] << thread
      thread
    end
  end

  after(:each) do
    # Deadline cleanup: join every spawned thread; kill stragglers so no
    # worker outlives the example and no flakiness can leak downstream.
    CLISCRIPT_RUNSPEC[:threads].each do |thread|
      begin
        thread.join(5)
      rescue StandardError
        nil
      end
      next unless thread.alive?

      thread.kill
      thread.join(2)
    end

    SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.clear } if Object.const_defined?(:SCRIPT_JOBS_MUTEX, false)
    SCRIPT_JOBS.clear unless Object.const_defined?(:SCRIPT_JOBS_MUTEX, false)
    SCRIPT_VARS[:job_counter] = 0

    Object.send(:remove_const, :Autohack) if Object.const_defined?(:Autohack, false)
    Object.const_set(:Autohack, @prior_autohack) if @prior_autohack
    Object.send(:remove_const, :Faketool) if Object.const_defined?(:Faketool, false)
  end

  after(:all) do
    # Tear down everything the REAL context file created plus the fake DSL
    # constants, restoring any pre-existing globals. Keeps the full suite's
    # CLI batch and Hackers modules exactly as they were.
    [:SCRIPT_DIR, :SCRIPT_EXT, :SCRIPT_JOBS, :SCRIPT_VARS, :SCRIPT_LOG_CHAR, :SCRIPT_LOGGER,
     :CONTEXT_SCRIPT_RUN, :CONTEXT_SCRIPT_KILL, :CONTEXT_SCRIPT_ADMIN].each do |constant|
      Object.send(:remove_const, constant) if Object.const_defined?(constant, false)
    end
    %i[script_run script_log_backtrace].each do |method|
      Object.send(:remove_method, method) if Object.private_method_defined?(method, false)
    end

    Object.send(:remove_const, :BASE_DIR) if Object.const_defined?(:BASE_DIR, false) && @prior_base_dir.nil?
    Object.send(:remove_const, :SHELL) if Object.const_defined?(:SHELL, false) && @prior_shell.nil?
    Object.send(:remove_const, :GAME) if Object.const_defined?(:GAME, false) && @prior_game.nil?
    Object.send(:remove_const, :CONTEXT_SCRIPT) if Object.const_defined?(:CONTEXT_SCRIPT, false) && @prior_context_script.nil?
    Object.send(:remove_const, :CLISCRIPT_RUNSPEC) if Object.const_defined?(:CLISCRIPT_RUNSPEC, false)
    Object.send(:remove_const, :Autohack) if Object.const_defined?(:Autohack, false) && @prior_autohack.nil?
    Thread.report_on_exception = @prior_report_on_exception unless @prior_report_on_exception.nil?

    Object.const_set(:BASE_DIR, @prior_base_dir[1]) if @prior_base_dir
    Object.const_set(:SHELL, @prior_shell[1]) if @prior_shell
    Object.const_set(:GAME, @prior_game[1]) if @prior_game
    Object.const_set(:CONTEXT_SCRIPT, @prior_context_script[1]) if @prior_context_script
  end

  context 'duplicate active autohack admission' do
    it 'reserves the active autohack before thread spawn and refuses a duplicate with no additional thread' do
      run_command!(['run', 'autohack'])
      main_event = next_event!(:main)
      expect(main_event[1]).to eq('Autohack')

      snapshot = jobs_snapshot
      expect(snapshot.length).to eq(1)
      expect(snapshot[0][:script]).to eq('autohack')
      expect(snapshot[0][:thread]).not_to be_nil # thread handle published into the reserved record
      expect(CLISCRIPT_RUNSPEC[:loads].length).to eq(1)

      run_command!(['run', 'autohack']) # second request while the first is still gated alive
      expect(output_text).to include('autohack is already running as job [1]; wait for it to finish')
      expect(CLISCRIPT_RUNSPEC[:loads].length).to eq(1) # refusal never loads the script file
      expect(CLISCRIPT_RUNSPEC[:threads].length).to eq(1) # refusal never spawns an additional thread

      _main_done, finish_event = release_main_and_hold_finish!(main_event)
      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])

      expect(jobs_snapshot).to be_empty
      expect_no_event! # exactly one canned instance-flow: the refusal created nothing
    end

    it 'recognizes ./autohack as the same canonical autohack job and refuses the other form' do
      run_command!(['run', './autohack'])
      main_event = next_event!(:main)

      snapshot = jobs_snapshot
      expect(snapshot.length).to eq(1)
      expect(snapshot[0][:script]).to eq('autohack') # identity normalized from the resolved file path
      # the exact typed file path is what gets loaded: no silent different file
      expect(CLISCRIPT_RUNSPEC[:loads]).to eq([File.join(SCRIPT_DIR, "./autohack#{SCRIPT_EXT}")])

      run_command!(['run', 'autohack']) # the equivalent spelling is refused
      expect(output_text).to include('autohack is already running as job [1]; wait for it to finish')
      expect(CLISCRIPT_RUNSPEC[:threads].length).to eq(1)

      _main_done, finish_event = release_main_and_hold_finish!(main_event)
      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])
      expect(jobs_snapshot).to be_empty
    end

    it 'permits a new autohack job after the previous run completes normally' do
      run_command!(['run', 'autohack'])
      main_event = next_event!(:main)
      _main_done, finish_event = release_main_and_hold_finish!(main_event)
      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])

      expect(jobs_snapshot).to be_empty # no persisted dead reservation after completion
      expect(output_text).to include('Done: autohack [1]')
      expect(SCRIPT_VARS[:job_counter]).to eq(1)

      run_command!(['run', 'autohack'])
      second_main = next_event!(:main) # re-admitted as a new job; nothing was left blocking
      expect(SCRIPT_VARS[:job_counter]).to eq(2) # counter advanced only for admitted jobs
      _second_done, second_finish = release_main_and_hold_finish!(second_main)
      second_finish[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][1])
      expect(jobs_snapshot).to be_empty
      expect(output_text).to include('Done: autohack [2]')
    end
  end

  context 'failure cleanup and release' do
    it 'releases the reservation when the script file raises SyntaxError during load and never calls finish' do
      CLISCRIPT_RUNSPEC[:loading_actions] = [:raise_syntax]
      run_command!(['run', 'autohack'])
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])

      expect(jobs_snapshot).to be_empty # ensure-based deletion covers even SyntaxError unwinds
      expect_no_event! # no canned instance ever existed: zero main/finish events
      expect(output_text).not_to include('Done: autohack [1]')
      expect(output_text).not_to include('Run: autohack [1]')

      run_command!(['run', 'autohack']) # future launches are possible after the failure
      expect(next_event!(:main)[0]).to eq(:main)
    end

    it 'logs the missing script class error and frees the job' do
      CLISCRIPT_RUNSPEC[:loading_actions] = [:no_define]
      run_command!(['run', 'autohack'])
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])

      expect(jobs_snapshot).to be_empty
      expect(output_text).to include('Error: autohack [1]')
      expect(output_text).to include('Class Autohack not found') # synthetic canned text, never a secret body
      expect_no_event!
      expect(output_text).not_to include('Done: autohack [1]')
    end

    it 'releases the reservation and re-raises when thread creation itself fails' do
      allow(Thread).to receive(:new).and_raise(ThreadError.new('mock spawn failure'))
      expect { run_command!(['run', 'autohack']) }.to raise_error(ThreadError)
      expect(jobs_snapshot).to be_empty # reservation released when the spawn fails
      expect(CLISCRIPT_RUNSPEC[:loads]).to be_empty
    end
  end

  context 'kill and running-cleanup semantics' do
    it 'kill invokes the finish hook exactly once, releases the job and allows a new run' do
      run_command!(['run', 'autohack'])
      _main_event = next_event!(:main)
      job_id = jobs_snapshot[0][:id]

      killer = Thread.new { @kill_cmd.exec(['kill', job_id.to_s]) }
      finish_event = next_event!(:finish) # the kill handler surfaces the canned finish
      finish_event[2] << :go
      wait_thread(killer)
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])

      expect(jobs_snapshot).to be_empty
      expect(output_text).to include("Killed: autohack [#{job_id}]")
      expect(output_text).not_to include('Done: autohack [1]')
      expect_no_event! # main never completed; finish ran exactly once

      run_command!(['run', 'autohack'])
      expect(next_event!(:main)[0]).to eq(:main) # admission possible right after the kill settled
    end

    it 'blocks a new autohack request while the running job still holds its cleanup, then releases it' do
      run_command!(['run', 'autohack'])
      main_event = next_event!(:main)
      _main_done, finish_event = release_main_and_hold_finish!(main_event)

      snapshot = jobs_snapshot
      expect(snapshot.length).to eq(1)
      expect(snapshot[0][:thread]).to be_alive # the worker still owns its cleanup

      run_command!(['run', 'autohack'])
      expect(output_text).to include('autohack is already running as job [1]; wait for it to finish')
      expect(CLISCRIPT_RUNSPEC[:threads].length).to eq(1)

      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])
      expect(jobs_snapshot).to be_empty
      expect(output_text).to include('Done: autohack [1]')
    end
  end

  context 'non-autohack script names stay concurrent' do
    it 'admits duplicate concurrent runs of another script name and releases both' do
      run_command!(['run', 'faketool'])
      run_command!(['run', 'faketool'])
      first = next_event!(:main)
      second = next_event!(:main)

      snapshot = jobs_snapshot
      expect(snapshot.length).to eq(2)
      expect(snapshot.map { |row| row[:script] }).to all(eq('faketool'))
      expect(CLISCRIPT_RUNSPEC[:threads].length).to eq(2)
      expect(output_text).not_to include('autohack is already running')

      first[2] << :go
      second[2] << :go
      _held, _released = release_finish_gates!(2) # order across worker threads not asserted
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])
      wait_thread(CLISCRIPT_RUNSPEC[:threads][1])
      expect(jobs_snapshot).to be_empty
    end
  end

  context 'jobs / kill / admin command behavior unchanged' do
    it 'jobs lists the active script in the legacy format' do
      run_command!(['run', 'autohack'])
      main_event = next_event!(:main)

      @jobs_cmd.exec(['jobs']) # real command object, real rendering path
      expect(output_text).to include('Active jobs:')
      expect(output_text).to include(' [1] autohack')
      expect(output_text).not_to include('No active jobs')

      _main_done, finish_event = release_main_and_hold_finish!(main_event)
      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])
      expect_no_event!
    end

    it 'kill and admin report a missing job without touching anything else' do
      @kill_cmd.exec(['kill', '99'])
      expect(output_text).to include('No such job')
      @admin_cmd.exec(['admin', '99'])
      expect(output_text.scan('No such job').length).to eq(2)
    end

    it 'admin reports Not implemented for a running job whose script lacks admin' do
      run_command!(['run', 'faketool'])
      main_event = next_event!(:main)

      @admin_cmd.exec(['admin', jobs_snapshot[0][:id].to_s])
      expect(output_text).to include('Not implemented')

      _main_done, finish_event = release_main_and_hold_finish!(main_event)
      finish_event[2] << :go
      wait_thread(CLISCRIPT_RUNSPEC[:threads][0])
      expect(jobs_snapshot).to be_empty
    end
  end
end
