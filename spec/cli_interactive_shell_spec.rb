# frozen_string_literal: true

require 'json'
require 'pty'
require 'rbconfig'
require 'shellwords'
require 'stringio'
require 'tmpdir'
require 'timeout'
require 'fileutils'

require 'sandbox'
require 'cli/sandbox'
require 'cli/colorterm'
require 'cli/misc'
require 'hackers'

require_relative 'support/callback_screen'
require 'cli/interactive_shell'

# Offline tests for the public-SDK interactive shell adapter (T0b2b).
#
# The adapter subclasses the installed SDK Sandbox::Shell and drives the
# proved GNU Readline callback module through public APIs only. Unit examples
# run against an injected fake native module; PTY examples run the real
# artifact and the real SDK shell end to end. No network, no real config
# files, no account: subprocess tests pass a synthetic config and a transport
# stub that only records request keys (and is never called in these flows).
REPO_ROOT = File.expand_path('..', __dir__)
BIN_PATH = File.join(REPO_ROOT, 'bin', 'sandbox')
NATIVE_ARTIFACT_NAME = 'cli_readline_callback'

# Deterministic offline stand-in for the CliReadlineCallback module. read_char
# consumes a scripted sequence (:pending/:eof/String), optionally running a
# test hook and the owner event proc first, mirroring the native await loop.
class FakeNativeModule
  attr_accessor :read_script, :during_read, :raise_error
  attr_reader :calls, :emit_messages, :history, :wake_count, :resize_count
  attr_reader :event_proc, :completion_proc, :session_prompts

  def initialize
    @calls = []
    @emit_messages = []
    @history = []
    @session_prompts = []
    @read_script = []
    @wake_count = 0
    @resize_count = 0
    @active = false
  end

  def version
    '8.3'
  end

  def install(prompt)
    raise 'fake session already active' if @active

    @calls << [:install, prompt]
    @active = true
  end

  def session(prompt)
    install(prompt)
    @session_prompts << prompt
    yield self
  ensure
    @calls << [:cleanup]
    @active = false
  end

  def read_char
    raise 'no active fake session' unless @active

    hook = @during_read
    @during_read = nil
    hook&.call
    event_proc&.call
    step = @read_script.shift
    raise 'fake read script exhausted' if step.nil?

    raise @raise_error if step == :raise

    step
  end

  def emit_message(message)
    raise 'no active fake session' unless @active

    @calls << [:emit, message]
    @emit_messages << message
  end

  def wake
    raise 'no active callback session' unless @active

    @wake_count += 1
  end

  def event=(callback)
    @event_proc = callback
  end

  def completion=(callback)
    @completion_proc = callback
  end

  def add_history(text)
    raise 'no active fake session' unless @active

    @history << text
  end

  def resize
    raise 'no active fake session' unless @active

    @resize_count += 1
  end

  def buffer
    ''
  end

  def point
    0
  end

  def remove
    @active = false
  end

  def active?
    @active
  end
end

RSpec.describe Sandbox::InteractiveShell do
  # --- Shared PTY child bookkeeping (T1 hoist) -------------------------------
  # Scoped to this example tree only: both the bin/sandbox entrypoint group
  # and the real-PTY-proof group record the pids of children THEY spawned and
  # reap them under bounded deadlines. No helper leaves this spec file.
  ##
  # Runtime-only child registration (not a repository source): when the
  # parent provides CLI_STRICT_PTY_PID_FILE (an exact locator under the
  # ignored run directory) plus a fresh opaque CLI_STRICT_PTY_RUN_NONCE,
  # every PTY child this harness spawned is appended as one JSONL line
  # (kind/pid/parent pid/nonce/monotonic only — no source bytes, no
  # secrets) so the parent can reap a child whose runner was externally
  # killed before the Ruby ensure ran. The harness records and later kills
  # ONLY pids it spawned itself; no ambient process discovery and no
  # cmdline reading. Fail-closed when the env path is set but unusable.
  define_method(:record_pty_manifest) do |kind, pid, mono|
    path = ENV['CLI_STRICT_PTY_PID_FILE']
    return if path.nil? || path.empty?

    nonce = ENV['CLI_STRICT_PTY_RUN_NONCE']
    raise 'CLI_STRICT_PTY_PID_FILE is set without CLI_STRICT_PTY_RUN_NONCE' if nonce.nil? || nonce.empty?

    File.open(path, 'a') do |file|
      file.puts(JSON.generate('kind' => kind, 'pid' => pid, 'parent_pid' => Process.pid,
                              'nonce' => nonce, 'mono' => mono))
      file.flush
    end
  end

  # Bounded nonblocking reap: polls WNOHANG until the limit. Returns the
  # exit status, or nil when the process did not terminate in time (best
  # effort inside ensure paths; the caller decides whether nil is fatal).
  define_method(:wait_child_bounded) do |pid, limit|
    loop do
      _pid, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if status

      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

      sleep 0.01
    end
  rescue Errno::ECHILD
    nil
  end

  describe 'fail-closed native selection' do
    it 'fails closed with an actionable build message when the artifact is missing' do
      stub_const('Sandbox::InteractiveShell::NATIVE_ARTIFACT', '/nonexistent/' + NATIVE_ARTIFACT_NAME)

      expect { described_class.load_native }
        .to raise_error(described_class::UnavailableError, /build_cli_readline_callback/)
    end

    it 'fails closed when the loaded native ABI version is unsupported' do
      wrong = FakeNativeModule.new
      allow(wrong).to receive(:version).and_return('9.9')

      expect { described_class.verify_native(wrong) }
        .to raise_error(described_class::UnavailableError, /GNU Readline 9\.9/)
    end

    it 'fails closed when the loaded native is missing a supported API' do
      incomplete = FakeNativeModule.new
      allow(incomplete).to receive(:respond_to?).and_call_original
      allow(incomplete).to receive(:respond_to?).with(:resize).and_return(false)

      expect { described_class.verify_native(incomplete) }
        .to raise_error(described_class::UnavailableError, /resize/)
    end

    it 'accepts the real artifact and verifies the full public API' do
      native = described_class.load_native

      expect(native.version).to eq('8.3')
      expect(native).to respond_to(
        :install, :session, :read_char, :emit_message, :remove, :buffer, :point,
        :wake, :event=, :completion=, :add_history, :resize
      )
    end
  end

  describe 'entrypoint class selection' do
    it 'keeps the original plain shell for batch/nonTTY streams' do
      allow($stdin).to receive(:tty?).and_return(false)
      allow($stdout).to receive(:tty?).and_return(false)

      expect(described_class.selected_shell_class).to be(Sandbox::Shell)
    end

    it 'selects the adapter only for an interactive TTY pair' do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdout).to receive(:tty?).and_return(true)

      expect(described_class.selected_shell_class).to be(described_class)
    end

    it 'fails closed on an interactive TTY when the artifact is missing' do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdout).to receive(:tty?).and_return(true)
      stub_const('Sandbox::InteractiveShell::NATIVE_ARTIFACT', '/nonexistent/' + NATIVE_ARTIFACT_NAME)

      expect { described_class.selected_shell_class }
        .to raise_error(described_class::UnavailableError)
    end
  end

  describe 'producer routing and owner rendering' do
    it 'queues producer output during an active editor and renders it from the owner only' do
      output = StringIO.new
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, output, native: native)
      producer_ran = Queue.new
      native.during_read = lambda do
        producer = Thread.new do
          shell.puts('incoming')
          shell.print('Usage: ')
          shell.puts('params')
          shell.print('tail-frag')
          producer_ran << true
        end
        producer.join
      end
      native.read_script = [:pending, 'done']

      expect(shell.readline('p> ', true)).to eq('done')

      expect(Timeout.timeout(2) { producer_ran.pop }).not_to be_nil
      # Complete producer lines rendered through the native owner path only.
      expect(native.emit_messages).to eq(['incoming', 'Usage: params'])
      # The producer wrote nothing directly to the output while editing; the
      # trailing print fragment is flushed raw at the boundary, without any
      # silently added newline.
      expect(output.string).to eq('tail-frag')
      expect(native.wake_count).to eq(4)
    end

    it 'keeps merging a print fragment across a later puts payload' do
      output = StringIO.new
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, output, native: native)
      native.during_read = -> do
        shell.print('partial ')
        shell.print('continued ')
        shell.puts('whole')
      end
      native.read_script = [:pending, 'done']

      shell.readline('p> ', false)

      expect(native.emit_messages).to eq(['partial continued whole'])
      expect(output.string).to be_empty
    end

    it 'emits complete payloads directly and serialized when the editor is inactive' do
      output = StringIO.new
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, output, native: native)

      shell.puts('before')
      shell.puts(['a', nil, 'b'])
      shell.puts("trailing\n")
      shell.puts
      shell.print('raw ')
      shell.print('bits')

      expect(output.string).to eq("before\na\n\nb\ntrailing\n\nraw bits")
      expect(native.wake_count).to eq(0)
    end

    it 'drains leftover queued bytes at the editor boundary without loss' do
      output = StringIO.new
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, output, native: native)
      native.during_read = lambda do
        producer = Thread.new { shell.puts('queued-late') }
        producer.join
        raise native.raise_error
      end
      native.read_script = [:pending, :raise]
      native.raise_error = RuntimeError.new('native boom')

      expect { shell.readline('p> ', false) }.to raise_error(RuntimeError, 'native boom')

      expect(output.string).to include('queued-late')
      expect(native.emit_messages).to be_empty
    end

    it 'serves a post-run producer with direct serialized output and no native wake error' do
      output = StringIO.new
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, output, native: native)
      native.read_script = ['first']

      expect(shell.readline('p> ', false)).to eq('first')

      late = Queue.new
      producer = Thread.new do
        shell.puts('late')
        late << true
      end
      expect(Timeout.timeout(2) { late.pop }).to be(true)
      expect(output.string).to include('late')
    end
  end

  describe 'readline lifecycle' do
    it 'returns the completed line and installs the wrapped prompt' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = [:pending, 'hello world']

      expect(shell.readline("\e[35;1m ▸ \e[0m", true)).to eq('hello world')

      expect(native.session_prompts).to eq(["\001\e[35;1m\002 ▸ \001\e[0m\002"])
      expect(native.calls).to include([:cleanup])
    end

    it 'leaves a plain prompt unchanged' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = ['x']

      shell.readline('p> ', false)

      expect(native.session_prompts).to eq(['p> '])
    end

    it 'returns nil on EOF' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = [:eof]

      expect(shell.readline('p> ', true)).to be_nil
    end

    it 'propagates a typed Interrupt instead of swallowing it as EOF' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = [:raise]
      native.raise_error = Interrupt

      expect { shell.readline('p> ', false) }.to raise_error(Interrupt)
    end

    it 'releases the persisted native event closure after every readline' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = ['x']

      shell.readline('p> ', false)

      expect(native.event_proc).to be_nil
    end
  end

  describe 'history policy' do
    def history_run(shell, native, lines)
      native.read_script = lines.flat_map { |line| [:pending, line] }
      lines.each { shell.readline('p> ', true) }
      native.history
    end

    it 'adds distinct lines through the native history API' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)

      expect(history_run(shell, native, ['alpha', 'beta'])).to eq(['alpha', 'beta'])
    end

    it 'skips blank lines and immediate duplicates like the SDK policy' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)

      expect(history_run(shell, native, ['alpha', '', 'beta', 'beta'])).to eq(['alpha', 'beta'])
    end

    it 'honors a false history argument with no native adds' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      native.read_script = ['alpha']

      shell.readline('p> ', false)

      expect(native.history).to be_empty
    end
  end

  describe 'public command completion derivation' do
    def complete(shell, native, prefix, full)
      # One readline installs the per-read completion deriver on the fake
      # native, exactly like a real session; then GNU's call shape is
      # reproduced directly.
      native.read_script = [:pending, 'done']
      shell.readline('p> ', false)
      native.completion_proc.call(prefix, full)
    end

    it 'derives tokens via the public path and calls the command proc with the SDK signature' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      context = shell.add_context(:chat, description: 'Chat')
      command = context.add_command(:open, description: 'Open', params: ['<room>']) { |_, sh| sh.puts('ok') }
      received = nil
      command.completion do |line, tokens, sh, ctx, cmd|
        received = [line, tokens, sh, ctx, cmd]
        ['999', '1000']
      end

      shell.path = [:chat]
      candidates = complete(shell, native, '99', 'open 99')

      expect(received).to eq(['99', %w[open 99], shell, context, command])
      expect(candidates).to eq(['999'])
    end

    it 'completes bare command names from the public context and global lists' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      shell.add_command(:hello, description: 'Hello') { |_, sh| sh.puts('hi') }
      shell.add_command(:área, description: 'Area') { |_, _sh| nil }

      expect(complete(shell, native, 'he', 'he')).to eq(%w[help hello])
      expect(complete(shell, native, 'ár', 'ár')).to eq(['área'])
    end

    it 'completes global commands inside a subcontext' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      shell.add_context(:chat, description: 'Chat')
      shell.add_command(:helpme, description: 'Global helper', global: true) { |_, _sh| nil }
      shell.path = [:chat]

      expect(complete(shell, native, 'hel', 'hel')).to eq(%w[help helpme])
    end

    it 'raises ShellError on bad quoting in the completion buffer' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)

      expect { complete(shell, native, 'he', "he 'unclosed") }
        .to raise_error(Sandbox::ShellError)
    end

    it 'returns nil for a nil candidate list without falling back' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      command = shell.add_command(:open, description: 'Open', params: ['<room>']) { |_, _sh| nil }
      command.completion { |_line| nil }

      expect(complete(shell, native, '9', 'open 9')).to be_nil
    end

    it 'normalizes binary-encoded buffers and refuses invalid UTF-8 loudly' do
      native = FakeNativeModule.new
      shell = described_class.new(StringIO.new, StringIO.new, native: native)
      shell.add_command(:hello, description: 'Hello') { |_, _sh| nil }

      expect(complete(shell, native, 'he', 'he'.b)).to eq(%w[help hello])
      expect { complete(shell, native, 'he', "he \xC3".dup.force_encoding(Encoding::UTF_8)) }
        .to raise_error(Sandbox::ShellError, /valid UTF-8/)
    end
  end

  describe 'periodic winsize sampler ownership' do
    it 'resizes exactly once when the sampled winsize changes under the owner' do
      input = StringIO.new
      def input.winsize
        @winsize ||= [24, 80]
      end
      def input.winsize=(value)
        @winsize = value
      end
      native = FakeNativeModule.new
      shell = described_class.new(input, StringIO.new, native: native)
      native.read_script = [:pending, 'x']

      input.winsize = [12, 40]
      expect(shell.readline('p> ', false)).to eq('x')

      expect(native.resize_count).to eq(1)
    end

    it 'does not resize when the sampled winsize is unchanged' do
      input = StringIO.new
      def input.winsize
        [24, 80]
      end
      native = FakeNativeModule.new
      shell = described_class.new(input, StringIO.new, native: native)
      native.read_script = [:pending, 'x']

      expect(shell.readline('p> ', false)).to eq('x')

      expect(native.resize_count).to eq(0)
    end
  end

  describe 'bin/sandbox entrypoint selection' do
    let(:dir) { Dir.mktmpdir('sandbox-interactive') }

    after { FileUtils.remove_entry(dir) }

    ##
    # Writes the test-only probe stub loaded through RUBYOPT. It pre-creates
    # the Hackers namespace the same way the batch spec's stub does, then the
    # real require reopens it with the prepend preserved. It records request
    # parameter keys and reports at exit whether the adapter/native module
    # were defined in that process. Never contacts anything.
    def write_probe_stub
      stub_path = File.join(dir, 'fake_transport_probe.rb')
      probe_path = File.join(dir, 'calls.jsonl')
      check_path = File.join(dir, 'check.json')
      File.write(stub_path, <<~RUBY)
        require 'json'
        module Hackers
          class RequestError < StandardError; end
        end
        CALLS_FILE = #{probe_path.inspect}
        CHECK_FILE = #{check_path.inspect}
        module Hackers
          class Client
            prepend(Module.new do
              def request_raw(params, data: {})
                File.open(CALLS_FILE, 'a') { |file| file.write(JSON.generate(params.keys) + "\\n") }
                raise 'no scripted transport in interactive tests'
              end
            end)
          end
        end
        at_exit do
          File.write(CHECK_FILE, JSON.generate(
            'adapter' => !defined?(Sandbox::InteractiveShell).nil?,
            'native' => !defined?(CliReadlineCallback).nil?
          ))
        end
      RUBY
      [stub_path, probe_path, check_path]
    end

    def synthetic_config
      config_path = File.join(dir, 'account.conf')
      File.write(config_path, JSON.generate('id' => 777, 'password' => 'synthetic-pw', 'version' => 1229))
      config_path
    end

    def run_bin(args, env_extra: {}, stdin_path: nil, timeout: 30)
      stub, calls_path, check_path = write_probe_stub
      config_path = synthetic_config
      env = ENV.to_h.merge('RUBYOPT' => "-r#{stub}").merge(env_extra)
      args = args.dup
      args.unshift('-c', config_path) unless args.include?('-c')

      out_r, out_w = IO.pipe
      pid = Process.spawn(env, RbConfig.ruby, BIN_PATH, *args, chdir: REPO_ROOT,
                          in: stdin_path || :in, out: out_w, err: out_w)
      out_w.close
      status = Timeout.timeout(timeout) { Process.wait2(pid)[1] }
      [out_r.read, status, calls_path, check_path]
    end

    define_method(:read_available) do |master, buffer|
      loop do
        buffer << master.read_nonblock(4096)
        buffer.force_encoding(Encoding::UTF_8)
      rescue IO::WaitReadable, EOFError
        return
      end
    end

    define_method(:await_output) do |master, pattern, message, timeout: 10, initial: ''|
      collected = initial.dup
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until collected.match?(pattern)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
          raise "#{message} not observed; collected=#{collected.inspect[0, 900]}"
        end

        master.wait_readable(0.2)
        read_available(master, collected)
      end
      collected
    end

    define_method(:run_with_pty) do |env_extra = {}, &block|
      stub, calls_path, check_path = write_probe_stub
      config_path = synthetic_config
      # Known-good minimal child environment: the bundle paths ride on the
      # project bundle's installed ruby directory (Bundler's GEM_HOME), the
      # transport stub loads via RUBYOPT, and stderr merges into the PTY so
      # typed UnavailableError output reaches the observer deterministically.
      env = {
        'PATH' => ENV['PATH'],
        'HOME' => ENV['HOME'],
        'LANG' => ENV['LANG'],
        'TERM' => 'xterm',
        'INPUTRC' => '/dev/null',
        'RUBYOPT' => "-r#{stub}",
        'GEM_HOME' => File.join(REPO_ROOT, '.bundle/native-readline/ruby/3.3.0'),
        'BUNDLE_PATH' => File.join(REPO_ROOT, '.bundle/native-readline'),
        'BUNDLE_APP_CONFIG' => File.join(REPO_ROOT, '.bundle'),
        'BUNDLE_GEMFILE' => File.join(REPO_ROOT, 'Gemfile')
      }.merge(env_extra)
      master, slave = PTY.open
      pid = Process.spawn(env, RbConfig.ruby, BIN_PATH, '-c', config_path, '-a',
                          chdir: REPO_ROOT, in: slave, out: slave, err: slave)
      record_pty_manifest('spawn', pid, Process.clock_gettime(Process::CLOCK_MONOTONIC))
      begin
        Timeout.timeout(15) { block.call(master, pid) }
      ensure
        # Streams close first so the child cannot block forever on its PTY,
        # then a bounded kill/reap: no unbounded Process.wait outside the
        # cleanup budget.
        slave.close unless slave.closed?
        master.close
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          nil
        end
        status = wait_child_bounded(pid, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5)
        record_pty_manifest('reaped', pid, Process.clock_gettime(Process::CLOCK_MONOTONIC))
        pid = nil
        status
      end
      [calls_path, check_path]
    end

    ##
    # One observation entry for every real-PTY entrypoint example: the exact
    # banner-then-prompt await pair. Centralizing the pair keeps the assertion
    # order identical everywhere while the boundary fix lives in this wrapper.
    define_method(:await_entrypoint_startup) do |master|
      banner_state = await_output(master, /Trickster Arts Hackers sandbox/, 'entrypoint banner')
      # Carry the ENTIRE unconsumed tail seen at the first banner match — not
      # a truncated window — so the prompt observation begins exactly where
      # the banner observation ended: a merged banner+prompt chunk is no
      # longer lost, and no byte observed before the banner can re-match
      # later (order preserved). The tail holds only actual read bytes from
      # this UTF-8 stream; no synthetic encoding state is injected.
      banner_match = banner_state.match(/Trickster Arts Hackers sandbox/)
      await_output(master, /\u25b8 /, 'entrypoint prompt', initial: banner_match.post_match)
    end

    it 'observes the entrypoint prompt when banner and prompt arrive merged in one chunk' do
      # Deterministic real-IO regression for the observation boundary: a REAL
      # pipe holds one prewritten banner+prompt burst and the writer stays
      # open, so exhausted reads are genuine EAGAIN (WaitReadable), never an
      # immediate EOFError. Exactly one read_nonblock chunk is deliverable —
      # the shape where one await consumes bytes the next await needs.
      burst = "Trickster Arts Hackers sandbox\n \u25b8 "
      read_end, write_end = IO.pipe
      write_end.write(burst)
      begin
        collected = await_entrypoint_startup(read_end)
        expect(collected.include?(" \u25b8 ")).to be(true)
      ensure
        write_end.close unless write_end.closed?
        read_end.close unless read_end.closed?
      end
    end

    it 'runs the real entrypoint on a TTY through the adapter and exits cleanly on EOF' do
      calls_path, check_path = run_with_pty do |master, pid|
        await_entrypoint_startup(master)
        master.write("\u0004")
        _pid, status = Process.wait2(pid)
        expect(status.exitstatus).to eq(0)
      end

      probe = JSON.parse(File.read(check_path))
      expect(probe['adapter']).to be(true)
      expect(probe['native']).to be(true)
      expect(File.file?(calls_path)).to be(false)
    end

    it 'fails closed before any backend request when the artifact is unavailable on a TTY' do
      calls_path, _check_path = run_with_pty('SANDBOX_NATIVE_CALLBACK' => '/nonexistent/' + NATIVE_ARTIFACT_NAME) do |master, pid|
        collected = +''
        loop do
          _pid, status = Process.waitpid2(pid, Process::WNOHANG)
          if status
            expect(status.exitstatus).to eq(1)
            expect(collected).to include('build_cli_readline_callback')
            break
          end

          master.wait_readable(0.2)
          read_available(master, collected)
        end
      end

      expect(File.file?(calls_path)).to be(false)
    end

    it 'keeps batch/nonTTY selection on the plain shell with zero backend requests' do
      stdin_path = File.join(dir, 'stdin.txt')
      File.write(stdin_path, '')

      out, status, calls_path, check_path = run_bin(['-e', 'help'], stdin_path: stdin_path)

      expect(status.exitstatus).to eq(0)
      expect(out).to include('help')
      expect(File.file?(calls_path)).to be(false)
      probe = JSON.parse(File.read(check_path))
      expect(probe['adapter']).to be(false)
      expect(probe['native']).to be(false)
    end

  end

  describe 'real PTY proof through the adapter and the SDK shell' do
    child = <<~'RUBY'
      require 'json'
      require 'io/console'
      # Route child diagnostics into the PTY stream so the parent harness
      # observes setup failures instead of losing them to inherited stderr.
      $stderr.reopen($stdout)
      repo = ARGV.fetch(0)
      $LOAD_PATH.unshift(File.join(repo, 'lib'))
      require 'sandbox'
      require 'cli/colorterm'
      require 'cli/sandbox'
      require 'cli/misc'
      require 'hackers'
      require 'cli/interactive_shell'

      control = IO.for_fd(3)
      events = IO.for_fd(4)
      events.sync = true
      STDOUT.sync = true

      def event(io, payload)
        io.puts(JSON.generate(payload))
      end

      at_exit do
        if $! && !$!.instance_of?(SystemExit)
          event(events, setup_error: "#{$!.class}: #{$!.message}\n#{$!.backtrace.first(6).join("\n")}")
        end
      end

      # Delegating parity facade (test fixture only, injected through the
      # adapter's public native: constructor seam): every adapter native call
      # forwards to the actual CliReadlineCallback module; observations stream
      # to the parent through the private records pipe. No fake renderer, no
      # native emit outside the SDK route, no new production API.
      #
      # Sparse emit telemetry: records store the SGR-stripped bare row (the
      # terminal renders SGR as pure attributes), capped at EMIT_RECORD_CAP
      # bytes. Larger rows are only counted; the counter is surfaced once via
      # owner_summary, so a ~256KiB producer frame never floods the records
      # pipe with per-line JSON.
      SANDBOX_SGR_SEQUENCE = Sandbox::InteractiveShell::SGR_SEQUENCE
      EMIT_RECORD_CAP = 128

      class ParityFacade
        attr_accessor :events_log

        def initialize(real)
          @real = real
          @records = Queue.new
          @install_id = nil
          @emit_ids = []
          @big_emits = 0
          @core_seq = 0
          @wake_seq = 0
        end

        # Owner-observed monotonic sequence for CORE records (session,
        # intent, emit, done-state, read): incremented at EVENT OBSERVATION
        # — intent BEFORE its real C call; read/emit/done-state AFTER the
        # real call returns — never at reporter-write or parent-read time.
        # Every core stamping runs on the owner thread, so no lock is
        # needed. Non-owner wake uses its own separate counter and never
        # participates in ordered state.
        def core_seq!
          @core_seq += 1
        end

        def records
          @records
        end

        %i[version install remove resize].each do |name|
          define_method(name) do |*args|
            result = @real.public_send(name, *args)
            @records << [name.to_s, result.to_s]
            result
          end
        end

        def wake
          result = @real.wake
          # Non-owner signal: separate counter, excluded from ordered state.
          @wake_seq += 1
          @records << ['wake', '', @wake_seq]
          result
        end

        def session(prompt, &block)
          @install_id = Thread.current.object_id
          @records << ['session', prompt, @install_id, 'start', core_seq!]
          result = @real.session(prompt, &block)
          @records << ['session', prompt, @install_id, 'end', core_seq!]
          result
        end

        def read_char
          result = @real.read_char
          state = begin
            [@real.buffer, @real.point]
          rescue StandardError
            nil
          end
          # SEQ stamped at observation, AFTER the real return (owner thread;
          # state read from the real public getters).
          @records << ['read', result.instance_of?(String) ? result : result.to_s, state, core_seq!]
          result
        end

        def emit_message(message)
          tid = Thread.current.object_id
          bare = message.gsub(SANDBOX_SGR_SEQUENCE, '')
          if bare == 'frame-start'
            # Owner-synchronous pre-emit INTENT record: one atomic syswrite
            # of a single <=PIPE_BUF JSON line DIRECTLY on the private
            # records pipe, BEFORE the real C emit. It never depends on the
            # Ruby reporter thread, which cannot obtain the GVL while the
            # owner blocks inside the C fputs on a backpressured master —
            # that starvation was the statically confirmed cycle. The mutex
            # serializes facade-side pipe writes but is never held across
            # C IO; the payload carries actual data only (no fake values).
            seq = core_seq!
            INTENT_LOCK.synchronize do
              @events_log.syswrite(JSON.generate('f' => ['intent', 'frame-start', tid, seq]) << "\n")
            end
          end
          @emit_ids << tid
          result = @real.emit_message(message)
          # SEQ stamped at observation, AFTER the real C emit returned (the
          # owner thread), never at reporter-write/parent-read time.
          seq = core_seq!
          if bare.bytesize <= EMIT_RECORD_CAP
            @records << ['emit', bare, tid, seq]
          else
            @big_emits += 1
          end
          if bare == 'frame-done'
            # END watermark record: real public getters, read after the
            # actual native frame-done emit but BEFORE returning to getc.
            # Legitimate exactly here: this facade method runs on the owner
            # thread inside the event hook under the GVL; the hook guard
            # blocks only read_char/install/remove re-entry, while
            # buffer/point check owner thread + active session only. A
            # failed read records nil — a concrete gap, never a fabricated
            # self-value; nothing is assigned.
            @records << ['done-state', post_emit_state, tid, core_seq!]
          end
          result
        end

        def post_emit_state
          buffer = begin
            @real.buffer
          rescue StandardError
            nil
          end
          point = begin
            @real.point
          rescue StandardError
            nil
          end
          [buffer, point]
        end

        def event=(callback)
          result = @real.event = callback
          @records << ['event_set', callback.nil?]
          result
        end

        def completion=(callback)
          result = @real.completion = callback
          @records << ['completion_set', callback.nil?]
          result
        end

        def add_history(text)
          result = @real.add_history(text)
          @records << ['history', text]
          result
        end

        def buffer
          @real.buffer
        end

        def point
          @real.point
        end

        def owner_summary
          { 'install' => @install_id, 'emits' => @emit_ids.uniq, 'big_emits' => @big_emits,
            'seq_total' => @core_seq }
        end
      end

      # Duck-typed offline game surface for the real chat context: no network,
      # no config files, no account.
      FakeMessage = Struct.new(:id, :name, :message, :experience)

      class FakeChat
        attr_reader :written

        def initialize
          @opened = nil
          @polls = 0
        end

        def opened?(room)
          @opened == room
        end

        def open(room)
          @opened = room
        end

        def close(room)
          @opened = nil if @opened == room
        end

        def read(room)
          @polls += 1
          # Exactly two real polls, then the poller stops cleanly (nil ends
          # the chat_read loop) so driver awaits stay deterministic.
          return nil if @polls > 2

          [FakeMessage.new(777, 'TestHero', "poll #{@polls}", 3)]
        end

        def write(room, text)
          @written = text
          []
        end
      end

      class FakeCountries
        def name(room)
          'World'
        end

        def select(*)
          []
        end
      end

      class FakeSettings
        def loaded?
          true
        end

        def get(key)
          key == 'chat_refresh_interval' ? 1 : nil
        end
      end

      class FakeExperience
        def loaded?
          false
        end
      end

      class FakeChatGame
        def initialize
          @chat = FakeChat.new
        end

        attr_reader :chat

        def countries_list
          FakeCountries.new
        end

        def app_settings
          FakeSettings.new
        end

        def experience_list
          FakeExperience.new
        end

        def connected?
          true
        end

        def session_active?
          true
        end
      end

      GAME = FakeChatGame.new
      require File.expand_path(File.join(repo, '.bundle', 'native-readline-callback', 'cli_readline_callback'))
      INTENT_LOCK = Mutex.new
      FACADE = ParityFacade.new(CliReadlineCallback)
      FACADE.events_log = events
      SHELL = Sandbox::InteractiveShell.new(prompt: ColorTerm.magenta.bold(" \u25b8 "), banner: 'fake chat PTY', native: FACADE)
      LOGGER = Sandbox::Logger.new(SHELL)
      CONTEXT_CHAT = SHELL.add_context(:chat, description: 'Internal chat')
      require File.join(repo, 'lib', 'cli', 'context', 'chat.rb')
      control.gets

      # Live records stream: the facade's queue is drained into the private
      # records pipe so the parent observes editor state mid-run, without any
      # terminal writes from this thread.
      reporter = Thread.new do
        loop do
          events.puts(JSON.generate({ 'f' => FACADE.records.pop }))
        end
      end

      # Fixed backpressure frame: ONE producer LOGGER.log call carries the
      # WHOLE frame as a single multiline payload — the three named markers
      # are lines inside it ('frame-start' + 256 padded lines + 'incoming'
      # + 'frame-done'; each padding line: 4-digit index, colon, 1010 'x'
      # bytes = 1015 chars). Joined with newlines the BODY is 260,127 bytes;
      # shell.puts adds one final newline (a grounded minimum, because the
      # body has no trailing LF) — the actual PTY wire count is HIGHER
      # (native LOGGER adds SGR sequences, the terminal applies ONLCR, GNU
      # redisplay adds redraw bytes) and is only ever used as an observed
      # value against that lower bound. ONE queue push and ONE wake; frame
      # atomicity is guaranteed by the adapter's OWN render loop
      # (render_active_bytes renders every line of the single queue entry
      # before any next key processing), so no keyboard polling can
      # interleave between frame transactions. The BODY bytesize is
      # instrumented once per run (payload_body_bytes event); the parent
      # asserts the observed value against its own independently computed
      # formula instead of assuming it.
      FRAME_LINES = 256
      FRAME_LINE_BODY = 'x' * 1010
      FRAME_MESSAGE = (['frame-start'] +
                       (0...FRAME_LINES).map { |i| format('%04d:%s', i, FRAME_LINE_BODY) } +
                       ['incoming', 'frame-done']).join("\n")
      event(events, payload_body_bytes: FRAME_MESSAGE.bytesize, payload_lines: FRAME_LINES + 3)

      mode = ARGV.fetch(1)

      before_stty = `stty -g`
      mode_fields = ->(m) { m.methods.grep(/^c_/).sort.map { |n| [n, m.public_send(n)] }.to_h }
      before_fields = mode_fields.call(STDIN.console_mode)
      restored_tty = -> { `stty -g` == before_stty && mode_fields.call(STDIN.console_mode) == before_fields }

      case mode
      when 'parity'
        # The frame producer is armed before the editing read but starts only
        # on the parent's 'frame' control command, so the frame provably
        # fires during the settled editing read (no sleep race) and the
        # buffer is retained. ONE LOGGER.log call carries the whole frame
        # (one push, one wake, atomic by the adapter's own render loop); the
        # actual default Sandbox::Logger renders every line bare (its
        # default log_prefix is empty); this is the chat/script producer
        # route (Sandbox::Logger -> shell.puts -> queue -> owner display).
        Thread.new do
          raise 'bad parity frame command' unless control.gets&.strip == 'frame'

          LOGGER.log(FRAME_MESSAGE)
        rescue StandardError => e
          event(events, producer_error: "#{e.class}: #{e.message}")
        end
      when 'complete'
        SHELL.add_command(:hello, description: 'Hello', params: ['<name>']) do |_tokens, sh|
          sh.puts('hi')
        end
        SHELL.add_command(:área, description: 'Area test') { |_tokens, _sh| nil }
      when 'interrupt'
        SHELL.add_command(:ask, description: 'Ask') do |_tokens, sh|
          sh.puts("confirmed=#{sh.confirm('Proceed', default: :y)}")
        end
      when 'surface', 'resize', 'scriptlog'
        SHELL.add_command(:echo, description: 'Echo the argument', global: true) do |tokens, sh|
          sh.puts("echo:#{tokens[1]}")
        end
      end

      if mode == 'scriptlog'
        BASE_DIR = ARGV.fetch(2)
        CONTEXT_SCRIPT = SHELL.add_context(:script, description: 'Scripts')
        require File.join(repo, 'lib', 'cli', 'context', 'script.rb')
      end

      SHELL.run

      event(events, owner_summary: FACADE.owner_summary)
      event(events, restored: restored_tty.call)
      event(events, written: GAME.chat.written) if mode == 'surface'
    RUBY

    # Fully bounded child termination: the caller closes the PTY master and
    # auxiliary pipes first so the child cannot block forever on its
    # streams; then TERM, a <=0.3s WNOHANG wait, KILL plus a bounded reap.
    # Never an unbounded Process.wait/Process.wait2 outside a deadline.
    define_method(:terminate_child_bounded) do |pid, deadline|
      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        nil
      end
      status = wait_child_bounded(pid, [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3].min)
      unless status
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          nil
        end
        status = wait_child_bounded(pid, deadline)
      end
      status
    end

    define_method(:with_adapter_pty) do |mode, script_dir: nil, &block|
      control_r, control_w = IO.pipe
      events_r, events_w = IO.pipe
      args = [REPO_ROOT, mode]
      args << script_dir if script_dir
      pid = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      PTY.spawn(ENV.to_h.merge('INPUTRC' => '/dev/null', 'TERM' => 'xterm'), RbConfig.ruby,
                '-e', child, *args, 3 => control_r, 4 => events_w) do |output, input, child_pid|
        pid = child_pid
        record_pty_manifest('spawn', pid, started)
        control_r.close
        events_w.close
        output.winsize = [12, 24]
        control_w.puts('start')
        # Streaming current-screen model: real PTY reads split at arbitrary
        # byte boundaries, so the SDK PTY readers must use the explicit
        # streaming decoder; the strict default stays reserved for the
        # native spec's whole-chunk inputs.
        screen = CallbackScreen.new(12, 24, streaming: true)
        # One shared monotonic deadline covers startup, blocking, read
        # records and the case itself: every awaiter works on the remaining
        # time and none ever resets it. The RSpec-level Timeout stays as a
        # backstop; bounded cleanup (<=1.5s) follows so startup + case +
        # cleanup fit inside the parent's effective 15s outer cap.
        @pty_deadline = started + 12.0
        @pty_raw_bytes = 0
        Timeout.timeout(15) { block.call(output, input, events_r, screen, pid, control_w) }
        status = terminate_child_bounded(pid, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5)
        raise "PTY child #{pid} did not exit after EOF within the bounded cleanup budget" if status.nil?

        record_pty_manifest('reaped', pid, Process.clock_gettime(Process::CLOCK_MONOTONIC))
        pid = nil
        expect(status.success?).to be(true)
      end
    ensure
      if pid
        terminate_child_bounded(pid, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5)
        record_pty_manifest('reaped', pid, Process.clock_gettime(Process::CLOCK_MONOTONIC))
        pid = nil
      end
      [control_r, control_w, events_r, events_w].compact.each { |io| io.close unless io.closed? }
    end

    define_method(:event_until) do |events, key|
      limit = shared_pty_deadline
      skipped = []
      loop do
        remaining = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "deadline exceeded awaiting #{key}; skipped=#{skipped.inspect}" if remaining <= 0
        raise 'event stream timeout' unless events.wait_readable(remaining)

        event = JSON.parse(events.gets || raise("child closed event pipe awaiting #{key}; skipped=#{skipped.inspect}"))
        return event if event.key?(key)

        skipped << event
      end
    end

    # Wrap-aware content search: SDK lines longer than the screen wrap, so
    # logical phrases may split across two model rows.
    define_method(:screen_text) do |screen|
      screen.lines.join('')
    end

    # Facade records: pops the private records pipe (bounded by the shared
    # monotonic deadline, never an unbounded gets), skipping non-facade
    # events, and returns the recorded array. Records are single-writer
    # JSON lines of at most PIPE_BUF bytes, so reads stay atomic.
    define_method(:facade_event) do |events|
      limit = shared_pty_deadline
      loop do
        remaining = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise 'facade record deadline exceeded' if remaining <= 0
        raise 'facade record timeout' unless events.wait_readable(remaining)

        event = JSON.parse(events.gets || raise('child closed event pipe'))
        return event['f'] if event.is_a?(Hash) && event.key?('f')
      end
    end

    # One multiplexed wait over the private records pipe AND the PTY master
    # under the remaining shared deadline. NORMAL shape (default): drain
    # the already-readable master bytes first, then return one ready
    # record — the legacy semantics, with no global drain limit while a
    # cursor observation runs. INTENT shape (record_first: true, used ONLY
    # by facade_intent for the producer-frame intent/big-emit windows,
    # where the intent is written by owner-direct syswrite BEFORE the C
    # emit): a ready record is consumed BEFORE any stdout drain, and until
    # the real rendered marker latches at most ONE bounded chunk is
    # drained per readiness round — so the record wait can never hold a
    # burst drain that scrolls a just-rendered transient row off the
    # bounded screen before any screen predicate runs again (only
    # await_screen evaluates the screen predicate). Once
    # @frame_marker_latched, bulk drains resume in both shapes.
    # Same-thread IO.select —
    # deliberately NO background reader thread, because pre-draining
    # everything would kill the real PTY backpressure the gate depends on;
    # the drain happens only while a record wait is actually open.
    define_method(:await_any_record) do |events, output, screen, record_first: false|
      limit = shared_pty_deadline
      loop do
        remaining = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise 'facade record deadline exceeded' if remaining <= 0

        ready = IO.select([events, output], nil, nil, remaining)
        raise 'facade record timeout' unless ready

        if record_first && ready[0].include?(events)
          event = JSON.parse(events.gets || raise('child closed event pipe'))
          next unless event.is_a?(Hash) && event.key?('f')

          return event['f']
        end

        drain_stdout(output, screen, max_reads: (record_first && @frame_marker_latched != true) ? 1 : nil) if ready[0].include?(output)

        next unless ready[0].include?(events)

        event = JSON.parse(events.gets || raise('child closed event pipe'))
        next unless event.is_a?(Hash) && event.key?('f')

        return event['f']
      end
    end

    # Owner-synchronous INTENT await: the record was written by the facade
    # BEFORE the real C emit of the named row, straight on the private
    # records pipe (never queued behind the GVL-starved reporter), so its
    # arrival proves the owner began that named render without depending
    # on the blocked C write itself.
    define_method(:facade_intent) do |events, output, screen, name|
      loop do
        item = await_any_record(events, output, screen, record_first: true)
        return item if item.is_a?(Array) && item[0] == 'intent' && item[1] == name
      end
    end

    # Nonblocking poll of already-arrived records: returns everything
    # immediately readable without waiting, for end-not-pending checks.
    define_method(:facade_poll) do |events|
      drained = []
      drained << JSON.parse(events.gets || raise('child closed event pipe')) while events.wait_readable(0)
      drained
    end

    # Scans read records until the editor state equals the expected settled
    # [buffer, point] pair; intermediate typing states are legitimate
    # skips. Bounded by the shared deadline and a hard record cap, never an
    # unlimited scan; the multiplex pump drains actual stdout concurrently.
    define_method(:facade_settled) do |events, output, screen, expected_buffer, expected_point|
      scanned = 0
      loop do
        raise 'facade settled record cap exceeded' if (scanned += 1) > 10_000

        item = await_any_record(events, output, screen)
        next unless item[0] == 'read'

        state = item[2]
        next if state.nil?

        return state if state == [expected_buffer, expected_point]
      end
    end

    # Causal frame window: consumes the private record stream from AFTER the
    # already-observed frame-start record until the frame-done emit record,
    # draining the actual PTY concurrently (the child's fputs blocks on the
    # full master until this loop reads it — the real backpressure release).
    # The owner must surface NO key-processing read record during the whole
    # frame; the FIRST read record after frame-done (the deferred key's
    # processing round) is returned together with the consumed window.
    # Causal frame window from the owner-observed INTENT watermark
    # (start_seq) to the done-state END watermark. Returns the window
    # records EXCLUDING the terminating post-done read (returned
    # separately), so the caller's no-read-inside assertion is well
    # defined and the previous version's self-contradiction (the
    # terminating read was collected into the window, making the boolean
    # always false) is fixed. Classification: records whose core seq is
    # OLDER than the intent watermark are late pre-frame arrivals and are
    # ignored; a true observed read inside the window raises typed with
    # the complete actual record; the terminating read must be a proper
    # POST-done read with a seq strictly greater than the done-state seq;
    # unclassifiable shapes raise typed with the complete observed value
    # instead of being silently ignored. Ordered records arriving late
    # (direct intent syswrite vs async reporter FIFO) are handled by seq
    # matching, never by arrival order.
    define_method(:facade_frame_window) do |events, output, screen, start_seq|
      seen_done = false
      end_seq = nil
      window = []
      loop do
        item = await_any_record(events, output, screen)

        case item[0]
        when 'read'
          next if item[3] && item[3] <= start_seq

          raise "owner processed a key during the frame (stage window, " \
                "seq #{item[3].inspect} vs intent watermark #{start_seq}, " \
                "end watermark #{end_seq.inspect}): #{item.inspect}" unless seen_done

          raise "read observed before the done-state end watermark despite " \
                "the frame-done emit (stage window): #{item.inspect}" if end_seq.nil?
          raise "post-done read seq #{item[3].inspect} does not strictly " \
                "exceed the end watermark #{end_seq.inspect} (stage post-done): #{item.inspect}" if item[3] <= end_seq

          return [window, item]
        when 'emit'
          seen_done = true if item[1] == 'frame-done'
          window << item
        when 'done-state'
          raise "done-state observed before the frame-done emit record " \
                "(stage window): #{item.inspect}" unless seen_done

          end_seq = item[3]
          window << item
        when 'intent'
          raise "frame-start intent re-observed inside the window " \
                "(stage window): #{item.inspect}"
        when 'wake', 'session', 'event_set', 'completion_set', 'history'
          next # non-core: never participates in ordered state
        else
          raise "unclassified record in frame window (stage window): #{item.inspect}"
        end
      end
    end

    # Deterministic read granularity for the screen-flow phase: a 128-byte
    # read can shift at most ~6 model rows (plus the two redraw rows an
    # emit burst appends), so a row rendered just ahead of the read stays
    # inside the bounded 12-row window at the next predicate check. This
    # is arithmetic on the read bound, never a timing heuristic. Used by
    # BOTH master drains (drain_stdout for the facade pumps and
    # await_screen) until the frame marker latches, then bulk reads resume.
    MARKER_PHASE_CHUNK = 128

    # Drains every immediately-readable stdout byte into the current-screen
    # model and the actual-bytes counter (never waits inside). `max_reads`
    # caps the drain to that many read rounds for the facade pumps before
    # the real rendered marker latches; the default stays the unbounded
    # ready-drain.
    define_method(:drain_stdout) do |output, screen, max_reads: nil|
      chunk_limit = @frame_marker_latched == true ? 16_384 : MARKER_PHASE_CHUNK
      reads = 0
      loop do
        break if max_reads && (reads += 1) > max_reads

        chunk = output.read_nonblock(chunk_limit)
        @pty_raw_bytes += chunk.bytesize
        screen.feed(chunk)
      end
    rescue IO::WaitReadable, Errno::EIO
      nil
    end

    define_method(:drain_screen) do |output, screen|
      while IO.select([output], nil, nil, 0.03)
        drain_stdout(output, screen)
      end
    end

    ##
    # One shared monotonic deadline for every awaiter of the current PTY
    # case (set once by with_adapter_pty at spawn time). Helpers never
    # reset it per record or per call; per-call relative budgets may only
    # tighten it.
    define_method(:shared_pty_deadline) do
      @pty_deadline or raise 'no shared PTY deadline: helper used outside with_adapter_pty'
    end

    ##
    # Drains output until the predicate holds against the current screen,
    # bounded by a wall-clock deadline under the shared PTY deadline so
    # every PTY gate stays deterministic. Tracks the actual bytes drained
    # from the master for the frame backpressure arithmetic.
    #
    # T3 marker observation: until the frame marker latches, reads stay at
    # MARKER_PHASE_CHUNK bytes so a just-rendered transient row (e.g.
    # frame-start) is still on the bounded screen when the predicate is
    # checked; the facade-intent pump (drain_stdout) obeys the same bound.
    # Once @frame_marker_latched, bulk reads resume. Read granularity
    # only — no sleep/poll of the native side, no timing heuristic, and no
    # assertion text is weakened anywhere.
    define_method(:await_screen) do |output, screen, deadline:, message:, &predicate|
      limit = [shared_pty_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline].min
      raw = +''
      until predicate.call(screen)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
          raise "#{message} not observed; screen=#{screen.lines.reject(&:empty?).inspect} raw=#{raw.inspect[-2000..]}"
        end

        next unless IO.select([output], nil, nil, 0.05)

        begin
          chunk = output.read_nonblock(
            @frame_marker_latched == true ? 16_384 : MARKER_PHASE_CHUNK
          )
          raw << chunk
          @pty_raw_bytes += chunk.bytesize
          screen.feed(chunk)
        rescue IO::WaitReadable
          nil
        rescue Errno::EIO
          # Child output finished; keep looping so the failure reports the
          # accumulated screen instead of crashing on the read.
          nil
        end
      end
      screen
    end

    ##
    # Full-strength SDK-parity gate (the native module's wrapped-frame test
    # does not transfer to the adapter on its own): real 50-ASCII input
    # settled at point 25 only through real key processing; a collision-free
    # key queued during a genuinely backpressured producer frame (one
    # LOGGER.log of a fixed 260,096-byte multiline payload — beyond any
    # ordinary PTY buffer — draining only through this PTY reader);
    # full wrapped prompt/entire input/exact cursor row+column on the
    # current screen, both mid-frame and after the deferred key; persistent
    # incoming; owner-only frames; and the exact eventual submission. The
    # default Sandbox::Logger renders its markers bare (its default
    # log_prefix is empty), so the assertions expect those actual rows.
    it 'defers a key queued during a backpressured producer frame with the full SDK wrapped screen and exact cursor' do
      with_adapter_pty('parity') do |output, input, events, screen, _pid, control|
        await_screen(output, screen, deadline: 5, message: 'banner') { |s| s.lines.include?('fake chat PTY') }
        await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/ ▸' }

        text = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX'
        submitted_text = text[0, 25] + '!' + text[25..]
        frame_lines = 256
        pty_buffer_margin = 65_536
        settled_rows = ('/ ▸ ' + text).each_char.each_slice(24).map(&:join)
        deferred_rows = ('/ ▸ ' + submitted_text).each_char.each_slice(24).map(&:join)

        # The BODY bytesize arrives from the child's one-time instrumentation
        # event (scope: the FRAME_MESSAGE string only — 256 padding lines of
        # 1015 chars + the three marker strings + 258 join separators, NO
        # trailing LF); the parent's formula is computed independently and
        # asserted against the observed value, never assumed equal in
        # silence and never collapsed into an expected==observed tautology.
        payload_event = event_until(events, 'payload_body_bytes')
        frame_body_bytes = payload_event.fetch('payload_body_bytes')
        frame_body_expected = 'frame-start'.bytesize + 'incoming'.bytesize +
                              'frame-done'.bytesize + frame_lines * 1015 + 258
        expect(frame_body_bytes).to eq(frame_body_expected)
        # Grounded OUTPUT LOWER BOUND: the actual body has no trailing LF,
        # and the public puts route adds exactly one final newline — so the
        # frame cannot cross the PTY with fewer than body+1 bytes. This is
        # a LOWER BOUND only, explicitly NOT the actual TTY wire byte count
        # (native LOGGER adds SGR sequences, the terminal applies ONLCR,
        # and GNU redisplay adds redraw bytes); the drained counter below
        # is the observed actual value and is compared against this bound,
        # never the reverse.
        frame_output_minimum_bytes = frame_body_bytes + 1

        input.write(text + ("\e[D" * 25))
        # Settled at point 25 by real key processing; observations come from
        # the delegating facade's live public-API records, never assignment.
        # The multiplex pump drains the PTY concurrently, so a record wait
        # can never starve the owner's C stdout emit on a full master.
        expect(facade_settled(events, output, screen, text, 25)).to eq([text, 25])

        # STABLE PRE-FRAME phase (no producer armed yet): the exact FULL
        # point-25 layout — wrapped prompt + ENTIRE 50-char input rows and
        # the exact cursor — asserted against the drained actual TTY.
        await_screen(output, screen, deadline: 3, message: 'pre-frame settled layout') do |s|
          s.lines.last(settled_rows.length) == settled_rows.map(&:rstrip)
        end
        # The settled redisplay crosses the master after its own read
        # record (owner-thread ordering: record pushed at facade level,
        # redisplay emitted after read_char returns), so the exact cursor
        # expect must observe the DRAINED actual cursor: this predicate
        # reads only the real current terminal bytes until the point-25
        # cursor shows, bounded by the shared deadline — never a sleep,
        # never a screen modification, and the exact expect below keeps
        # its full [10, 5] strength.
        await_screen(output, screen, deadline: 3, message: 'pre-frame settled cursor') do |s|
          [s.row, s.column] == [10, 5]
        end
        expect([screen.row, screen.column]).to eq([10, 5])
        expect(screen_text(screen)).not_to include('!')

        # Arm the producer through the control pipe: the frame provably
        # fires during this same editing read (the buffer is retained). The
        # owner publishes the frame-start INTENT record synchronously
        # BEFORE the real C emit (sparse, actual owner tid), so the intent
        # proves the render began independently of the blocked C write;
        # the multiplex pump keeps the master draining while awaiting it.
        control.puts('frame')
        intent_record = facade_intent(events, output, screen, 'frame-start')
        expect(intent_record[2]).to be_a(Integer)
        expect(intent_record[3]).to be_a(Integer)

        # Actual TTY bytes, not metadata: the bare logger row crossed the
        # master. While the ~260K-byte payload flows the marker row can
        # scroll off; appearing once through the live current-screen model
        # is the barrier proof — it is NEVER required to REMAIN visible.
        await_screen(output, screen, deadline: 5, message: 'frame-start row') do |s|
          s.lines.include?('frame-start')
        end
        # Marker captured through the bounded read phase: the observed row
        # is the marker TEXT on the live current-screen model, and the rest
        # of the frame is still queued behind the real backpressure — the
        # read side has NOT drained the whole frame. Bulk reads resume only
        # now (for the later window/redraw await phases), BEFORE the
        # deferred key is queued, so the causal mid-frame key ordering and
        # the drained-bytes inequality below stay exactly as written.
        @frame_marker_latched = true

        # PHASE CORRECTION (honest disclosure): the immediately previous
        # round asserted the full exact input layout MID-frame, but the
        # native clear-visible-line during the C print is transient by
        # design, so that claim was wrong; the exact wrapped rows and
        # cursor are asserted at the STABLE pre-frame phase above and at
        # the STABLE post-key phase below instead — never weakened, never
        # hidden behind a contains-only check.

        # Causal proof at the key write: (a) the owner actually began
        # rendering the frame (private frame-start record with owner tid),
        # (b) actual stdout bytes are flowing (drained counter on the real
        # PTY), and (c) no frame-done record — emit marker or sparse
        # done-state snapshot — is pending. The drained-bytes inequality
        # below additionally rests on a PTY-buffer ASSUMPTION (<= 65,536
        # bytes; generous over Linux defaults): it is NOT a measured TRUE
        # PTY capacity and NOT a grounded API guarantee, and this fixture
        # never changes kernel settings. The completion floor is the
        # grounded OUTPUT LOWER BOUND (body 260,127 + one puts LF); the
        # actual wire count is higher and only ever observed.
        expect(@pty_raw_bytes).to be < frame_output_minimum_bytes - pty_buffer_margin
        end_not_ready = lambda do |event|
          record = event['f']
          record.is_a?(Array) &&
            (record[0] == 'done-state' || (record[0] == 'emit' && record[1] == 'frame-done'))
        end
        expect(facade_poll(events).none?(&end_not_ready)).to be(true)

        # Collision-free key queued while the frame is still active.
        input.write('!')

        # The key must be UNPROCESSED at frame-done, bound to the real SDK
        # route: the sparse done-state snapshot is read through the real
        # public buffer/point getters inside the owner's frame-done emit
        # path (after the real C emit returned, before native getc) and
        # must equal the exact settled [text, 25]; the window excludes the
        # terminating post-done read and any true pre-end read raises typed
        # inside the helper; the FIRST later read after the queued key
        # carries the already-inserted state.
        window, post_done = facade_frame_window(events, output, screen, intent_record[3])
        expect(window.none? { |item| item[0] == 'read' }).to(be(true),
          "frame window unexpectedly contains pre-end read records (stage window): " \
          "#{window.select { |item| item[0] == 'read' }.inspect}")
        frame_start_done = window.detect { |item| item[0] == 'emit' && item[1] == 'frame-start' }
        expect(frame_start_done).not_to be_nil,
          "post-emit frame-start completion record missing (stage window): #{window.inspect}"
        expect(frame_start_done[2]).to eq(intent_record[2])
        incoming_done = window.detect { |item| item[0] == 'emit' && item[1] == 'incoming' }
        expect(incoming_done).not_to be_nil,
          "post-emit incoming completion record missing (stage window): #{window.inspect}"
        expect(incoming_done[2]).to eq(intent_record[2])
        frame_done_done = window.detect { |item| item[0] == 'emit' && item[1] == 'frame-done' }
        expect(frame_done_done).not_to be_nil,
          "post-emit frame-done completion record missing (stage window): #{window.inspect}"
        expect(frame_done_done[2]).to eq(intent_record[2])
        done_state = window.detect { |item| item[0] == 'done-state' }
        expect(done_state).not_to be_nil,
          "done-state snapshot missing (stage frame-done): #{window.inspect}"
        expect(done_state[1]).to eq([text, 25]),
          "frame-done public buffer/point snapshot mismatch (stage frame-done): #{done_state.inspect}"
        expect(done_state[2]).to eq(intent_record[2]),
          "done-state owner tid mismatch (stage frame-done): #{done_state.inspect} intent=#{intent_record.inspect}"
        expect(post_done[0]).to eq('read')
        expect(post_done[1]).to eq('pending')
        expect(post_done[2]).to eq([submitted_text, 26]),
          "first post-frame read state mismatch (stage post-done): #{post_done.inspect}"
        expect(post_done[3]).to be > done_state[3],
          "post-done read seq #{post_done[3].inspect} must strictly exceed the " \
          "end watermark #{done_state[3].inspect} (stage post-done): #{post_done.inspect}"

        # After the deferred key processed: exact wrapped prompt+input rows
        # with '!', exact cursor, both last markers persistent on the
        # current screen.
        await_screen(output, screen, deadline: 5, message: 'deferred-key redraw') do |s|
          s.lines.last(deferred_rows.length) == deferred_rows.map(&:rstrip) &&
            [s.row, s.column] == [10, 6] &&
            s.lines.include?('incoming') && s.lines.include?('frame-done')
        end
        expect([screen.row, screen.column]).to eq([10, 6])

        # Submit: the SDK dispatch echoes the unrecognized token (wrapped
        # across rows); the submitted read record is the second, independent
        # exactness proof.
        input.write("\r")
        # Parity-echo correction (accepted 2026-10): the SDK downcases the
        # first token IN PLACE before any echo — verbatim on-disk sources
        # read directly (external gem, not CodeGraph-indexed):
        #   .bundle/native-readline/ruby/3.3.0/gems/sandbox-ruby-0.1/lib/
        #     sandbox/shell.rb:185  "tokens.first&.downcase!" (split_tokens)
        #   .../sandbox/context.rb:102 and :125 —
        #     'shell.puts("Unrecognized command: #{tokens.first}")'
        # The submitted line is a single whitespace-free command token, so
        # the echo is its full downcase; the DIFFERENT-CASE identity proof
        # stays in the read-record assertions below (submitted_record).
        await_screen(output, screen, deadline: 5, message: 'submitted dispatch row') do |s|
          screen_text(s).include?("Unrecognized command: #{submitted_text.downcase}")
        end
        submitted_record = nil
        loop do
          item = facade_event(events)
          next unless item[0] == 'read'

          submitted_record = item
          break if item[1] == submitted_text
        end
        expect(submitted_record[1]).to eq(submitted_text)

        # The frame really crossed the PTY: once the pipe is drained quiet,
        # the parent must have observed at least the grounded output
        # minimum (body + one puts LF); the observed actual wire count is
        # expected to be higher (SGR/ONLCR/redisplay bytes) and is only
        # ever read as an observed value.
        drain_screen(output, screen)
        expect(@pty_raw_bytes).to be >= frame_output_minimum_bytes
        expect(screen.unknown).to be_empty
        # Stream-end validation at the stable declared end: the child is
        # idle after the full quiet drain; no unfinished UTF-8 prefix or
        # escape sequence may remain.
        screen.finish!
        input.write("\u0004")
        owner = event_until(events, 'owner_summary')['owner_summary']
        expect(owner['emits']).to eq([owner['install']])
        expect(owner['big_emits']).to eq(frame_lines)
        expect(owner['seq_total']).to be > done_state[3]
        expect(event_until(events, 'restored')['restored']).to be(true)
      end
    end

    # T4 regression (deterministic, no PTY child): two real IO pipes with
    # the event JSON and the frame burst prewritten make the
    # both-streams-ready race permanent instead of scheduler dependent.
    # The intent record is already readable on the records pipe when the
    # child's real frame burst is readable on the PTY master, so the
    # ACTUAL pump (facade_intent -> await_any_record -> drain_stdout)
    # faces both fds ready on its FIRST select round; the marker capture
    # itself goes through the ACTUAL await_screen on a real CallbackScreen.
    it 'protects the rendered frame-start marker while the facade record and the frame burst are both readable' do
      events_r, events_w = IO.pipe
      output_r, output_w = IO.pipe
      begin
        # Actual private-records wire format from the child: one JSON line,
        # `f` => ['intent', 'frame-start', owner tid, core seq].
        fixture_record = { 'f' => ['intent', 'frame-start', 4_242, 7] }
        # Every 62-char filler line wraps into exactly 3 model rows on the
        # 24-column screen; 1 + 1 + 20*3 + 1 rows push the marker (>12
        # rows behind) deterministically off the bounded 12-row screen as
        # soon as the whole burst has been fed. Prewritten below the pipe
        # capacity in one write, and writers stay open (closed in ensure)
        # so exhaustion reads behave like the real EAGAIN, never EOFError.
        burst = (['frame-start', 'incoming'] +
                 Array.new(20) { |i| format('filler-%02d %s', i, 'z' * 52) } +
                 ['frame-done']).join("\n") + "\n"
        events_w.sync = true
        events_w.write(JSON.generate(fixture_record) << "\n")
        output_w.write(burst)

        # Both streams already readable: the exact race shape, verified
        # before any helper runs.
        expect(IO.select([events_r, output_r], nil, nil, 0)[0]).to include(events_r, output_r)

        # The shared monotonic deadline the helpers require (normally set
        # by with_adapter_pty at spawn time) — fresh per example, never
        # global state.
        @pty_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10.0
        @pty_raw_bytes = 0
        screen = CallbackScreen.new(12, 24, streaming: true)

        obtained = facade_intent(events_r, output_r, screen, 'frame-start')
        expect(obtained).to eq(fixture_record['f'])

        await_screen(output_r, screen, deadline: 2, message: 'frame-start row') do |s|
          s.lines.include?('frame-start')
        end

        # The record was obtained before the marker could be lost, and the
        # burst crossed in bounded pre-marker chunks only: the design
        # allows exactly one MARKER_PHASE_CHUNK read, with the rest still
        # queued behind the real backpressure.
        expect(@pty_raw_bytes).to eq(MARKER_PHASE_CHUNK)
        expect(IO.select([output_r], nil, nil, 0)[0]).to include(output_r)

        # The latch set only after the genuine screen predicate captured
        # the marker (never on a raw drained substring): bulk drain resumes
        # unchanged and all remaining bytes cross exactly once.
        @frame_marker_latched = true
        drain_stdout(output_r, screen)
        drain_screen(output_r, screen)
        expect(@pty_raw_bytes).to eq(burst.bytesize)
        expect(IO.select([output_r], nil, nil, 0)).to be_nil

        # Stream-end validation at the stable declared end: the burst is
        # plain ASCII ended with a newline, so nothing may remain carried.
        screen.finish!
        expect(screen.unknown).to be_empty
      ensure
        [events_r, events_w, output_r, output_w].compact.each { |io| io.close unless io.closed? }
      end
    end

    it 'proves the colored prompt, chat surface, producer queue and nested talk in a real PTY' do
      with_adapter_pty('surface') do |output, input, events, screen, _pid|
        await_screen(output, screen, deadline: 5, message: 'banner') { |s| s.lines.include?('fake chat PTY') }
        await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/chat ▸' ? false : s.lines.last == '/ ▸' }

        # Enter the chat context: the dynamic path appears in the prompt.
        input.write("chat\n")
        await_screen(output, screen, deadline: 5, message: 'dynamic path prompt') { |s| s.lines.last == '/chat ▸' }

        # Open room 999: the real poller renders its first poll directly.
        # The chat line is 31 visible columns: it wraps as
        # "❤ [World:999] ? TestHero" + " poll 1" on the 24-column screen.
        input.write("open 999\n")
        await_screen(output, screen, deadline: 5, message: 'first poll') do |s|
          screen_text(s).include?('TestHero poll 1')
        end

        # Enter nested talk and type while the producer is not yet polling.
        input.write("talk 999\n")
        await_screen(output, screen, deadline: 5, message: 'nested talk prompt') { |s| s.lines.last == 'World:999 ❥' }
        input.write('ab')
        await_screen(output, screen, deadline: 5, message: 'typed buffer') { |s| s.lines.last == 'World:999 ❥ ab' }

        # The poller's next poll must arrive DURING the edit, rendered by the
        # owner from the queue, with the prompt/input intact afterwards.
        await_screen(output, screen, deadline: 5, message: 'producer poll during edit') do |s|
          screen_text(s).include?('TestHero poll 2') && s.lines.last == 'World:999 ❥ ab'
        end

        # Finish the message and leave talk through the documented interface;
        # the poller has already stopped, so last-row awaits are stable. The
        # exact 'abcd' submission is proven by the child's written event.
        input.write("cd\n")
        await_screen(output, screen, deadline: 5, message: 'back at nested prompt') { |s| s.lines.last == 'World:999 ❥' }
        input.write("!\n")
        await_screen(output, screen, deadline: 5, message: 'back at main prompt') do |s|
          s.lines.last.start_with?('/chat ▸')
        end

        input.write("alpha\n")
        input.write("\n")
        input.write("beta\n")
        input.write("beta\n")
        await_screen(output, screen, deadline: 5, message: 'prompt after submissions') do |s|
          s.lines.last == '/chat ▸' && screen_text(s).include?('Unrecognized command: beta')
        end
        input.write("\e[A")
        await_screen(output, screen, deadline: 5, message: 'recall newest') { |s| s.lines.last == '/chat ▸ beta' }
        input.write("\e[A")
        await_screen(output, screen, deadline: 5, message: 'recall past skipped entries') { |s| s.lines.last == '/chat ▸ alpha' }

        # Final submission proof through a global command, then EOF.
        input.write("\r")
        input.write("echo final\n")
        await_screen(output, screen, deadline: 5, message: 'echo submission') { |s| s.lines.include?('echo:final') }
        drain_screen(output, screen)
        expect(screen.unknown).to be_empty
        # Stream-end validation at the stable declared end: the child is
        # idle after the full quiet drain; no unfinished UTF-8 prefix or
        # escape sequence may remain.
        screen.finish!
        input.write("\u0004")
        expect(event_until(events, 'restored')['restored']).to be(true)
        expect(event_until(events, 'written')['written']).to eq('abcd')
      end
    end

    it 'completes ambiguous command names and a UTF-8 name through the public SDK path' do
      with_adapter_pty('complete') do |output, input, events, screen, _pid|
        await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/ ▸' }

        input.write('he')
        await_screen(output, screen, deadline: 5, message: 'typed prefix') { |s| s.lines.last == '/ ▸ he' }
        input.write("\t")
        await_screen(output, screen, deadline: 5, message: 'multi-candidate completion') { |s| s.lines.last == '/ ▸ hel' }
        input.write("\r")
        await_screen(output, screen, deadline: 5, message: 'completed submission') do |s|
          screen_text(s).include?('Unrecognized command: hel')
        end

        input.write("ár")
        await_screen(output, screen, deadline: 5, message: 'typed UTF-8 prefix') { |s| s.lines.last == '/ ▸ ár' }
        input.write("\t")
        await_screen(output, screen, deadline: 5, message: 'UTF-8 completion') { |s| s.lines.last == '/ ▸ área' }
        input.write("\r")
        await_screen(output, screen, deadline: 5, message: 'UTF-8 submission') do |s|
          screen_text(s).include?('/ ▸ área') && s.lines.last == '/ ▸'
        end
        drain_screen(output, screen)
        expect(screen.unknown).to be_empty
        # Stream-end validation at the stable declared end: the child is
        # idle after the full quiet drain; no unfinished UTF-8 prefix or
        # escape sequence may remain.
        screen.finish!
        input.write("\u0004")
        expect(event_until(events, 'restored')['restored']).to be(true)
      end
    end

    it 'cancels the nested confirm on SIGINT and keeps the shell alive with restored TTY' do
      with_adapter_pty('interrupt') do |output, input, events, screen, pid|
        await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/ ▸' }

        input.write("ask\n")
        await_screen(output, screen, deadline: 5, message: 'nested confirm prompt') do |s|
          s.lines.last == 'Proceed (y/n) [y]'
        end
        input.write('x')
        await_screen(output, screen, deadline: 5, message: 'typed confirm input') do |s|
          s.lines.last == 'Proceed (y/n) [y] x'
        end

        sleep 0.05
        Process.kill('INT', pid)
        await_screen(output, screen, deadline: 5, message: 'fresh prompt after SIGINT') { |s| s.lines.last == '/ ▸' }

        # The shell is alive after the interrupt: confirm again to completion.
        input.write("ask\n")
        await_screen(output, screen, deadline: 5, message: 'nested confirm prompt again') do |s|
          s.lines.last == 'Proceed (y/n) [y]'
        end
        input.write("y\n")
        await_screen(output, screen, deadline: 5, message: 'confirmed line') { |s| screen_text(s).include?('confirmed=true') }
        drain_screen(output, screen)
        expect(screen.unknown).to be_empty
        # Stream-end validation at the stable declared end: the child is
        # idle after the full quiet drain; no unfinished UTF-8 prefix or
        # escape sequence may remain.
        screen.finish!
        input.write("\u0004")
        expect(event_until(events, 'restored')['restored']).to be(true)
      end
    end

    it 'reflows the editor on a real PTY winsize change through the sampler' do
      with_adapter_pty('resize') do |output, input, events, screen, _pid|
        await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/ ▸' }

        text = 'echo ' + 'abcdefghijklmnopqrstuvwxyz01234'
        input.write(text)
        await_screen(output, screen, deadline: 5, message: 'wrapped rows') do |s|
          s.lines.last(2) == [('/ ▸ ' + text)[0, 24], ('/ ▸ ' + text)[24..]]
        end

        output.winsize = [12, 40]
        resized_screen = CallbackScreen.new(12, 40, streaming: true)
        await_screen(output, resized_screen, deadline: 5, message: 'reflowed single row') do |s|
          s.lines.first.length == 40 && s.lines.first.end_with?('abcdefghijklmnopqrstuvwxyz01234')
        end
        screen = resized_screen
        input.write("\r")
        await_screen(output, screen, deadline: 5, message: 'submission after resize') do |s|
          screen_text(s).include?("echo:#{text.delete_prefix('echo ')}")
        end
        drain_screen(output, screen)
        expect(screen.unknown).to be_empty
        # Stream-end validation at the stable declared end: the child is
        # idle after the full quiet drain; no unfinished UTF-8 prefix or
        # escape sequence may remain.
        screen.finish!
        input.write("\u0004")
        expect(event_until(events, 'restored')['restored']).to be(true)
      end
    end

    it 'routes the script logger producer through the owned shell in a real PTY' do
      Dir.mktmpdir('sandbox-script-logger') do |base_dir|
        scripts_dir = File.join(base_dir, 'scripts')
        FileUtils.mkdir_p(scripts_dir)
        File.write(File.join(scripts_dir, 'logtest.rb'), <<~'SCRIPT')
          class Logtest < Sandbox::Script
            def main
              sleep 0.4
              @logger.log('script log line')
              @logger.error('script error line')
            end
          end
        SCRIPT

        with_adapter_pty('scriptlog', script_dir: base_dir) do |output, input, events, screen, _pid|
          await_screen(output, screen, deadline: 5, message: 'root prompt') { |s| s.lines.last == '/ ▸' }

          input.write("script\n")
          await_screen(output, screen, deadline: 5, message: 'script prompt') { |s| s.lines.last == '/script ▸' }
          input.write("run logtest\n")
          await_screen(output, screen, deadline: 5, message: 'script run acknowledgement') do |s|
            s.lines.include?('✿ Run: logtest [1]')
          end

          # The script sleeps inside its thread; its logger lines must arrive
          # during the next editing read through the owned shell.
          input.write("echo before\n")
          await_screen(output, screen, deadline: 5, message: 'echo before script lines') do |s|
            s.lines.include?('echo:before')
          end
          await_screen(output, screen, deadline: 5, message: 'script log during edit') do |s|
            screen_text(s).include?('script log line') && screen_text(s).include?('script error line')
          end
          drain_screen(output, screen)
          expect(screen.unknown).to be_empty
          # Stream-end validation at the stable declared end (see the
          # other cases): the child is idle after the full quiet drain.
          screen.finish!
          input.write("\u0004")
            expect(event_until(events, 'restored')['restored']).to be(true)
        end
      end
    end
  end
end

# Pure-model regression group for the streaming current-screen decoder used
# by the SDK PTY readers (arbitrary read_nonblock chunk boundaries). All
# inputs are synthetic known text; no PTY, no child process, no SDK load.
RSpec.describe CallbackScreen do
  describe 'streaming mode for arbitrary PTY chunk boundaries (SDK PTY readers only)' do
    def streaming_screen
      described_class.new(12, 24, streaming: true)
    end

    it 'completes a prompt glyph split at every single-byte boundary, advancing cells only when complete' do
      screen = streaming_screen
      raw = '/ ▸ x'.b
      screen.feed(raw[0, 3]) # '/ ' + the '▸' lead \xE2
      # T2 (accepted rationale): `lines` is the normalized ROW presentation
      # (trailing blanks trimmed), so an open row holding '/ ' plus a still
      # pending glyph reads as '/'. The SPACE itself is proven consumed as a
      # real cell by the independent cursor position assertions below:
      # column 2 with the glyph deferred until completion — a swallowed byte
      # or non-advanced column could not produce [row, column] == [0, 2].
      expect(screen.lines.first).to eq('/')
      expect([screen.row, screen.column]).to eq([0, 2])
      screen.feed(raw[3, 1]) # the \x96 continuation, still incomplete
      expect(screen.lines.first).to eq('/')
      expect([screen.row, screen.column]).to eq([0, 2])
      screen.feed(raw[4..]) # \xB8 completes '▸', then ' x'
      expect(screen.lines.first).to eq('/ ▸ x')
      expect([screen.row, screen.column]).to eq([0, 5])
      expect(screen.unknown).to be_empty
      expect(screen.finish!).to be(screen)
    end

    it 'completes a typed UTF-8 glyph split across two chunks' do
      screen = streaming_screen
      screen.feed('h'.b)
      screen.feed("\xC3".b) # 'á' lead, incomplete at this chunk end
      expect(screen.lines.first).to eq('h')
      expect([screen.row, screen.column]).to eq([0, 1])
      screen.feed("\xA1".b) # completes 'á'
      expect(screen.lines.first).to eq('há')
      expect([screen.row, screen.column]).to eq([0, 2])
      expect(screen.finish!).to be(screen)
    end

    it 'carries the unfinished prefix across an empty intermediate read' do
      screen = streaming_screen
      raw = '/ ▸ y'.b
      screen.feed(raw[0, 3])
      screen.feed(''.b) # empty read: restore, still incomplete, re-carry
      # Normalized presentation again; see the first streaming example for
      # the full accepted rationale — the cursor pair proves the space.
      expect(screen.lines.first).to eq('/')
      expect([screen.row, screen.column]).to eq([0, 2])
      screen.feed(raw[3..])
      expect(screen.lines.first).to eq('/ ▸ y')
      expect([screen.row, screen.column]).to eq([0, 5])
    end

    it 'fails typed on an invalid sequence completing across chunks' do
      screen = streaming_screen
      screen.feed("\xC3".b)
      expect { screen.feed("\x28".b) }.to raise_error(RuntimeError, /invalid UTF-8 sequence/)
    end

    it 'fails typed on an untested glyph completing across chunks' do
      screen = streaming_screen
      screen.feed("\xE2".b)
      expect { screen.feed("\x9C\xA0".b) }.to raise_error(RuntimeError, /untested non-ASCII glyph/)
    end

    it 'fails when finalized with a carried unfinished prefix' do
      screen = streaming_screen
      screen.feed("\xE2".b)
      expect { screen.finish! }.to raise_error(RuntimeError, /unfinished UTF-8 prefix/)
    end

    it 'fails when finalized with an unfinished escape sequence' do
      screen = streaming_screen
      screen.feed("\e[".b)
      expect { screen.finish! }.to raise_error(RuntimeError, /unfinished escape sequence/)
    end

    it 'keeps the default strict feed immediately fatal on a chunk-split glyph' do
      screen = described_class.new(12, 24) # strict default, unchanged
      expect { screen.feed('/ ▸ x'.b[0, 3]) }.to raise_error(RuntimeError, /truncated UTF-8/)
    end
  end
end
