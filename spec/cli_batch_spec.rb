# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'sandbox'
require 'cli/sandbox'
require 'cli/batch'
require 'hackers'

# Offline tests for the batch command runner and the real bin/sandbox
# entrypoint (task C1).
#
# Process-level tests replace ONLY the network transport: a test stub loaded
# through RUBYOPT intercepts Hackers::Client#request_raw, serves synthetic
# payloads and records request parameter keys. No test contacts the game
# server, reads real config files or uses real credentials.
RSpec.describe Sandbox::Batch do
  let(:output) { StringIO.new }
  let(:shell) { Sandbox::Shell.new(StringIO.new, output) }
  let(:logger) { Sandbox::Logger.new(shell) }

  subject(:batch) { described_class.new(shell, logger) }

  before do
    shell.add_command(:ok_cmd, description: 'Always ok') do |tokens, sh|
      sh.puts('done')
    end

    shell.add_command(:fail_cmd, description: 'Always fails') do |_tokens, _sh|
      logger.error('boom')
    end

    shell.add_command(:two_args, description: 'Needs two args', params: ['<a>', '<b>']) do |tokens, sh|
      sh.puts("got #{tokens[1]} #{tokens[2]}")
    end

    context_demo = shell.add_context(:demo, description: 'Demo context')
    context_demo.add_command(:greet, description: 'Greets', params: ['<name>']) do |tokens, sh|
      sh.puts("hi #{tokens[1]}")
    end
  end

  describe 'command resolution' do
    it 'executes root commands' do
      expect(batch.run(['ok_cmd'])).to be(true)
      expect(output.string).to include('done')
    end

    it 'routes space-separated context commands through the registry' do
      expect(batch.run(['demo greet World'])).to be(true)
      expect(output.string).to include('hi World')
    end

    it 'routes slash-separated context commands' do
      expect(batch.run(['demo/greet World'])).to be(true)
      expect(output.string).to include('hi World')
    end

    it 'enters contexts like the interactive shell does' do
      expect(batch.run(['demo'])).to be(true)
      expect(batch.run(['greet World'])).to be(true)
      expect(output.string).to include('hi World')
    end

    it 'fails on unknown commands' do
      expect(batch.run(['no_such_command'])).to be(false)
      expect(output.string).to include('Unrecognized command')
    end

    it 'fails on unknown commands inside contexts' do
      expect(batch.run(['demo bogus'])).to be(false)
    end

    it 'fails on missing mandatory arguments before executing' do
      expect(batch.run(['two_args only-one'])).to be(false)
      expect(output.string).not_to include('got only-one')
    end

    it 'fails on malformed quoting' do
      expect(batch.run(["greet 'unclosed"])).to be(false)
    end

    it 'fails when the command reports a logger error' do
      expect(batch.run(['fail_cmd'])).to be(false)
      expect(output.string).to include('boom')
    end
  end

  describe 'fail-fast sequencing' do
    it 'stops remaining commands after the first failure' do
      ok = batch.run(['fail_cmd', 'ok_cmd'])

      expect(ok).to be(false)
      expect(output.string).not_to include('done')
    end

    it 'reports each executed command in order' do
      batch.run(['ok_cmd', 'fail_cmd'])

      expect(batch.results.map(&:command)).to eq(['ok_cmd', 'fail_cmd'])
      expect(batch.results.map(&:ok)).to eq([true, false])
      expect(batch.results.last.error).to include('boom')
    end
  end

  describe 'structured JSON summary' do
    subject(:batch) { described_class.new(shell, logger, json: true) }

    it 'emits a safe summary without ids, tokens or credentials' do
      batch.run(['ok_cmd'])

      summary = JSON.parse(output.string.strip.lines.last)
      expect(summary).to include(
        'ok' => true,
        'own_name' => nil,
        'own_message_seen' => false,
        'chat_message_count' => 0
      )
      expect(summary['commands']).to eq([{ 'command' => 'ok_cmd', 'ok' => true }])
    end

    it 'includes failures in the summary' do
      batch.run(['fail_cmd'])

      summary = JSON.parse(output.string.strip.lines.last)
      expect(summary['ok']).to be(false)
      expect(summary['commands'].first).to include('ok' => false, 'error' => 'boom')
    end
  end

  describe 'failure reporting hygiene' do
    before do
      shell.add_command(:raise_cmd, description: 'Raises a generic error') do |_tokens, _sh|
        raise(RuntimeError, 'TOPSECRET_MSG')
      end

      shell.add_command(:reqerr_cmd, description: 'Raises a request error') do |_tokens, _sh|
        raise Hackers::RequestError.new('RequestLimit', 'rate limited', http_status: 429)
      end
    end

    it 'withholds unknown untrusted exception messages' do
      batch.run(['raise_cmd'])

      expect(batch.results.last.ok).to be(false)
      expect(batch.results.last.error).to eq('RuntimeError')
      expect(output.string).not_to include('TOPSECRET_MSG')
    end

    it 'preserves mapped request errors and safe HTTP status evidence' do
      batch.run(['reqerr_cmd'])

      expect(batch.results.last.ok).to be(false)
      expect(batch.results.last.error).to include('RequestLimit')
      expect(batch.results.last.error).to include('rate limited')
      expect(batch.results.last.error).to include('429')
      expect(output.string).not_to include('Hackers::RequestError:')
    end

    it 'reports malformed quoting statically without echoing the raw line' do
      batch.run(["greet 'TOPSECRET_UNCLOSED"])

      expect(batch.results.last.ok).to be(false)
      expect(output.string).to include('Malformed command quoting')
      expect(output.string).not_to include('TOPSECRET_UNCLOSED')
      expect(output.string).not_to include('NoMethodError')
    end

    it 'does not echo arguments of failed unknown commands' do
      batch.run(['no_such_command', 'TOPSECRET_ARG'])

      expect(batch.results.first.ok).to be(false)
      expect(output.string).not_to include('TOPSECRET_ARG')
      expect(output.string).to include('Unrecognized command')
    end

    it 'still stops following mutating commands after a hygiene failure' do
      expect(batch.run(['raise_cmd', 'ok_cmd'])).to be(false)
      expect(output.string).not_to include('done')
    end
  end
end

RSpec.describe 'bin/sandbox batch entrypoint' do
  REPO_ROOT = File.expand_path('..', __dir__)
  BIN_PATH = File.join(REPO_ROOT, 'bin', 'sandbox')
  EXACT_NAME = '[ff0000]βℓąȼЌhąţhąȼЌ€я'
  DEFAULT_AUTH = '0,0,0,SIDTEST123,4,500'
  SYNTHETIC_ID = 777
  SYNTHETIC_PASSWORD = 'synthetic-pw-№1'

  let(:dir) { Dir.mktmpdir('sandbox-batch') }

  after { FileUtils.remove_entry(dir) }

  ##
  # Writes the test-only transport stub loaded through RUBYOPT. It intercepts
  # Hackers::Client#request_raw only — nothing else under test is replaced.
  def write_transport_stub(auth_payload, chat_payload, chat_send_payload: nil, chat_read_payload: nil)
    default_chat_expr = '"1000,Alice,hello,55,60,3,999;1001," + STATE[:name] + ",Test,777,60,3,999"'
    chat_expr = chat_payload ? chat_payload.inspect : default_chat_expr
    chat_send_expr = chat_send_payload ? chat_send_payload.inspect : chat_expr
    chat_read_expr = chat_read_payload ? chat_read_payload.inspect : chat_expr
    profile_expr = '"777," + STATE[:name] + ",100,50,10,500,0,0,0,3,0,0,0,0,0"'

    <<~RUBY
      require 'json'

      module Hackers
        class RequestError < StandardError; end
      end

      module FakeTransport
        CALLS_FILE = #{File.join(dir, 'calls.jsonl').inspect}
        STATE = { name: 'TestHero' }
        HANDLERS = {
          'auth_id_password' => ->(_params) { #{auth_payload.inspect} },
          'player_get_info' => ->(_params) { #{profile_expr} },
          'player_set_name_once' => ->(params) { STATE[:name] = params['name']; '1' },
          'chat_display' => ->(_params) { #{chat_read_expr} },
          'chat_send' => ->(_params) { #{chat_send_expr} }
        }
      end

      module Hackers
        class Client
          prepend(Module.new do
            def request_raw(params, data: {})
              File.open(FakeTransport::CALLS_FILE, 'a') do |file|
                file.write(JSON.generate(params.keys) + "\\n")
              end

              handler = FakeTransport::HANDLERS[params.keys.first]
              raise Hackers::RequestError, 'no scripted response' if handler.nil?

              handler.call(params)
            end
          end)
        end
      end
    RUBY
  end

  ##
  # Runs bin/sandbox as a real subprocess with the transport stub.
  def run_sandbox(args, auth_payload: DEFAULT_AUTH, chat_payload: nil, chat_send_payload: nil,
                  chat_read_payload: nil, stdin_data: nil, config_data: nil, timeout: 30)
    calls_path = File.join(dir, 'calls.jsonl')
    FileUtils.rm_f(calls_path)
    stub_path = File.join(dir, 'fake_transport.rb')
    File.write(
      stub_path,
      write_transport_stub(
        auth_payload,
        chat_payload,
        chat_send_payload: chat_send_payload,
        chat_read_payload: chat_read_payload
      )
    )

    config_path = File.join(dir, 'account.conf')
    File.write(
      config_path,
      JSON.generate(config_data || { 'id' => SYNTHETIC_ID, 'password' => SYNTHETIC_PASSWORD, 'version' => 1229 })
    )

    env = ENV.to_h.merge('RUBYOPT' => "-r#{stub_path}")
    args = args.dup
    args.unshift('-c', config_path) unless args.include?('-c')
    stdin_file = File.join(dir, 'stdin.txt')
    File.write(stdin_file, stdin_data) if stdin_data

    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(
      env, RbConfig.ruby, BIN_PATH, *args, chdir: REPO_ROOT,
      out: out_w, err: err_w, in: stdin_data ? stdin_file : :in
    )
    out_w.close
    err_w.close

    deadline = Time.now + timeout
    status = nil
    loop do
      _pid, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status
      raise "sandbox subprocess timed out: #{args.inspect}" if Time.now > deadline

      sleep(0.05)
    end

    [out_r.read, err_r.read, status, calls_path, config_path]
  end

  def recorded_calls(calls_path)
    return [] unless File.file?(calls_path)

    File.readlines(calls_path).map { |line| JSON.parse(line) }
  end

  def json_summary(output)
    JSON.parse(output.strip.lines.last)
  end

  describe 'intended live-proof batch sequence (offline rehearsal)' do
    it 'runs connect, name, rename, expect, say and read in at most six RPCs' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m',
         '-e', 'connect',
         '-e', 'name',
         '-e', "rename '#{EXACT_NAME}'",
         '-e', "name --expect '#{EXACT_NAME}'",
         '-e', 'chat say 999 Test',
         '-e', 'chat read 999',
         '--json']
      )

      expect(status.exitstatus).to eq(0)

      calls = recorded_calls(calls_path)
      expect(calls.length).to eq(6)
      expect(calls.map(&:first)).to eq(
        %w[auth_id_password player_get_info player_set_name_once player_get_info chat_send chat_display]
      )
      catalog_keys = %w[
        i18n_translations_get_language app_setting_get_list get_node_types_and_levels
        get_program_types_and_levels missions_get_list get_skin_types get_hints_list
        get_experience_list get_builders_list get_goal_types get_shield_types get_rank_list
      ]
      expect(calls.flatten).not_to include(*catalog_keys)

      summary = json_summary(out)
      expect(summary['ok']).to be(true)
      expect(summary['own_name']).to eq(EXACT_NAME)
      expect(summary['own_message_seen']).to be(true)
      expect(summary['chat_message_count']).to eq(2)
      expect(summary['commands'].map { |c| c['ok'] }).to eq([true] * 6)
    end

    it 'confirms a read echo in the caller room despite different country metadata' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'name', '-e', 'chat say 999 Test', '-e', 'chat read 999', '--json'],
        chat_send_payload: '1000,Other,hello,55,60,3,4', chat_read_payload: '1001,TestHero,Test,777,60,3,4'
      )

      expect(status.exitstatus).to eq(0)
      expect(recorded_calls(calls_path).map(&:first)).to eq(%w[auth_id_password player_get_info chat_send chat_display])
      expect(json_summary(out)).to include('own_message_seen' => true, 'chat_message_count' => 1)
    end

    it 'skips the rename when the cached own name is already exact' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'name', '-e', "rename 'TestHero'", '--json']
      )

      expect(status.exitstatus).to eq(0)
      calls = recorded_calls(calls_path)
      expect(calls.map(&:first)).to eq(%w[auth_id_password player_get_info])
      expect(json_summary(out)['ok']).to be(true)
    end

    it 'preserves the exact UTF-8 name through tokenization and the wire call' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', "rename '#{EXACT_NAME}'", '--json']
      )

      expect(status.exitstatus).to eq(0)
      expect(json_summary(out)['ok']).to be(true)

      rename_call = recorded_calls(calls_path).detect { |c| c.first == 'player_set_name_once' }
      expect(rename_call).to include('name')
    end

    it 'runs requested reads before reporting an unconfirmed outgoing send' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'chat say 999 MissingEcho', '-e', 'chat read 999', '--json'],
        chat_send_payload: '1000,Alice,hello,55,60,3,999',
        chat_read_payload: '1000,Alice,hello,55,60,3,999'
      )

      expect(status.exitstatus).to eq(1)
      calls = recorded_calls(calls_path)
      expect(calls.map(&:first)).to eq(%w[auth_id_password chat_send chat_display])

      summary = json_summary(out)
      expect(summary['ok']).to be(false)
      expect(summary['chat_publication_status']).to eq('unconfirmed')
      expect(summary['commands'].map { |c| c['ok'] }).to eq([true, true, true])
    end

    it 'requires each distinct outgoing send to be echoed by own id and exact text' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'chat say 999 First', '-e', 'chat say 999 Second',
         '-e', 'chat read 999', '--json'],
        chat_send_payload: '1001,TestHero,First,777,60,3,999',
        chat_read_payload: '1001,TestHero,First,777,60,3,999'
      )

      expect(status.exitstatus).to eq(1)
      expect(recorded_calls(calls_path).map(&:first)).to eq(
        %w[auth_id_password chat_send chat_send chat_display]
      )

      summary = json_summary(out)
      expect(summary['ok']).to be(false)
      expect(summary['own_message_seen']).to be(false)
      expect(summary['chat_publication_status']).to eq('unconfirmed')
    end

    it 'does not reuse one identical owned echo across repeated identical sends and readback' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'chat say 999 Same', '-e', 'chat say 999 Same',
         '-e', 'chat read 999', '--json'],
        chat_send_payload: '1001,TestHero,Same,777,60,3,999',
        chat_read_payload: '1001,TestHero,Same,777,60,3,999'
      )

      expect(status.exitstatus).to eq(1)
      expect(recorded_calls(calls_path).map(&:first)).to eq(
        %w[auth_id_password chat_send chat_send chat_display]
      )

      summary = json_summary(out)
      expect(summary['ok']).to be(false)
      expect(summary['own_message_seen']).to be(false)
      expect(summary['chat_publication_status']).to eq('unconfirmed')
    end

    it 'does not let a pre-observed identical owned echo confirm a later send' do
      out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'chat read 999', '-e', 'chat say 999 Same',
         '-e', 'chat read 999', '--json'],
        chat_send_payload: '1001,TestHero,Same,777,60,3,999',
        chat_read_payload: '1001,TestHero,Same,777,60,3,999'
      )

      expect(status.exitstatus).to eq(1)
      expect(recorded_calls(calls_path).map(&:first)).to eq(
        %w[auth_id_password chat_display chat_send chat_display]
      )

      summary = json_summary(out)
      expect(summary['ok']).to be(false)
      expect(summary['own_message_seen']).to be(false)
      expect(summary['chat_publication_status']).to eq('unconfirmed')
    end
  end

  describe 'fail-fast behavior' do
    it 'stops after an empty session id and exits nonzero' do
      _out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'name', '--json'],
        auth_payload: '0,0,0,,4,500'
      )

      expect(status.exitstatus).to eq(1)
      expect(recorded_calls(calls_path).length).to eq(1)
    end

    it 'fails on unknown commands' do
      _out, _err, status, _calls, _config = run_sandbox(['-m', '-e', 'definitely_not_a_command'])

      expect(status.exitstatus).to eq(1)
    end

    it 'fails on missing mandatory arguments' do
      _out, _err, status, _calls, _config = run_sandbox(['-m', '-e', 'chat say 999'])

      expect(status.exitstatus).to eq(1)
    end

    it 'fails on malformed quoting' do
      _out, _err, status, _calls, _config = run_sandbox(['-m', '-e', "rename 'unclosed"])

      expect(status.exitstatus).to eq(1)
    end

    it 'never leaks synthetic credentials in errors or output' do
      out, err, _status, _calls, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'name', '--json'],
        auth_payload: '0,0,0,,4,500'
      )

      expect(out + err).not_to include(SYNTHETIC_PASSWORD)
      expect(out + err).not_to include(SYNTHETIC_ID.to_s)
    end
  end

  describe 'untrusted chat text' do
    it 'does not alter batch status when messages contain failure-like text' do
      hostile = "1000,Evil,Unrecognized command: rm -rf,55,60,3,999;" \
                "1001,Evil2,\e[31m✘ fake failure\e[0m,66,60,3,999"

      _out, _err, status, calls_path, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'chat read 999', '--json'],
        chat_payload: hostile
      )

      expect(status.exitstatus).to eq(0)
      expect(recorded_calls(calls_path).map(&:first)).to eq(%w[auth_id_password chat_display])
    end
  end

  describe 'autocmd and interactive behavior' do
    it 'skips autocmd execution in batch mode' do
      out, _err, status, _calls, _config = run_sandbox(
        ['-m', '-e', 'connect', '-e', 'name', '--json'],
        config_data: { 'id' => SYNTHETIC_ID, 'password' => SYNTHETIC_PASSWORD, 'version' => 1229,
                       'autocmd' => ['echo version'] }
      )

      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('1229')
    end

    it 'keeps autocmd execution in interactive mode' do
      out, _err, status, _calls, _config = run_sandbox(
        [],
        stdin_data: "quit\n",
        config_data: { 'id' => SYNTHETIC_ID, 'password' => SYNTHETIC_PASSWORD, 'version' => 1229,
                       'autocmd' => ['echo version'] }
      )

      expect(status.exitstatus).to eq(0)
      expect(out).to include('1229')
    end

    it 'exits cleanly on interactive EOF' do
      _out, _err, status, _calls, _config = run_sandbox([], stdin_data: '')

      expect(status.exitstatus).to eq(0)
    end
  end

  describe 'entrypoint smoke' do
    it 'prints help without any network access' do
      out, _err, status, calls_path, _config = run_sandbox(['--help'])

      expect(status.exitstatus).to eq(0)
      expect(out).to include('Trickster Arts Hackers sandbox')
      expect(out).to include('--execute')
      expect(out).to include('--minimal')
      expect(recorded_calls(calls_path)).to be_empty
    end

    it 'fails friendly on a missing explicit config path' do
      out, _err, status, _calls, _config = run_sandbox(
        ['-c', File.join(dir, 'missing.conf')]
      )

      expect(status.exitstatus).to eq(1)
      expect(out).to include("doesn't exist")
    end
  end
end
