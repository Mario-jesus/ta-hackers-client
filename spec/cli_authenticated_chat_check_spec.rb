# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../scripts/cli_authenticated_chat_check'

RSpec.describe CliAuthenticatedChatCheck do
  # Every runtime fixture is disposable and synthetic. Only Net::HTTP is
  # replaced: the real entrypoint, signing, serializers and dispatch execute.
  def run_fake(name: described_class::EXPECTED_NAME, auth: '0,0,0,SYNTHETIC_SESSION,4,500',
               chat: '1000,Alice,hello,55,60,3,999', timeout_at: nil, config: {}, extra: [], profile_id: 777, profile_body: nil, status_at: nil,
               batch_bodies: nil, disk_failure: nil)
    Dir.mktmpdir('authenticated-chat-spec') do |dir|
      account = File.join(dir, 'synthetic.json')
      attempt = File.join(dir, 'attempt')
      File.write(account, JSON.generate({ id: 777, password: 'synthetic-password', version: 1229 }.merge(config)))
      runner = File.join(dir, 'runner.rb')
      File.write(runner, <<~RUBY)
        require 'net/http'
        require 'json'
        require #{File.expand_path('../scripts/cli_authenticated_chat_check', __dir__).inspect}
        calls = []
        starts = []
        reads = []
        trace = []
        syncs = []
        original_write = File.instance_method(:write)
        File.define_method(:write) do |data|
          if #{disk_failure.inspect} == 'short-write' && File.basename(path) == 'send-1.json'
            original_write.bind_call(self, data[0, 1])
          else
            original_write.bind_call(self, data)
          end
        end
        original_fsync = File.instance_method(:fsync)
        File.define_method(:fsync) do
          if path == #{dir.inspect} || path.start_with?(#{attempt.inspect})
            syncs << (path == #{dir.inspect} ? 'parent' : File.basename(path))
            raise IOError, 'PRIVATE_DISK_ERROR' if File.basename(path) == #{disk_failure.inspect} ||
              (#{disk_failure.inspect} == 'send-directory' && path == #{attempt.inspect} && syncs[-2] == 'send-1.json')
          end
          original_fsync.bind_call(self)
        end
        original_read = File.method(:read)
        File.define_singleton_method(:read) do |path, *args, **kwargs|
          reads << caller_locations.first.path if path == #{account.inspect}
          original_read.call(path, *args, **kwargs)
        end
        Net::HTTP.class_eval do
          define_method(:start) do |&block|
            reservation = File.join(#{attempt.inspect}, 'reservation.json')
            raise 'missing reservation before transport' unless File.file?(reservation)
            raise 'non-private reservation' unless (File.stat(reservation).mode & 0o777) == 0o600
            raise 'attempt directory not durable' if #{!extra.empty?} && !syncs.include?('parent')
            starts << calls.length + 1
            block ? block.call(self) : self
          end
          define_method(:request) do |request, *_args, &block|
            pairs = URI.decode_www_form(URI(request.path).query)
            rpc = pairs.map(&:first).find { |key| %w[auth_id_password player_get_info chat_display chat_send].include?(key) }
            calls << rpc
            params = pairs.to_h
            if rpc == 'chat_send'
              index = calls.count('chat_send')
              reservation = File.join(#{attempt.inspect}, "send-\#{index}.json")
              raise 'missing durable send reservation' unless File.file?(reservation) &&
                (File.stat(reservation).mode & 0o777) == 0o600 && syncs.last(2) == ["send-\#{index}.json", 'attempt']
            end
            trace << { rpc: rpc, room_ok: params['room'].nil? || params['room'] == '999',
                       owner_ok: params['id_player'].nil? || params['id_player'] == '777',
                       session_ok: params['session_id'].nil? || params['session_id'] == 'SYNTHETIC_SESSION',
                       text: params['message'], cursor: params['last_message'] }
            raise Net::ReadTimeout, 'PRIVATE_EXCEPTION' if calls.length == #{timeout_at.inspect}
            body = case rpc
            when 'auth_id_password' then #{auth.inspect}
            when 'player_get_info' then #{(profile_body || "#{profile_id},#{name},100,50,10,500,0,0,0,3,0,0,0,0,0").inspect}
            when 'chat_display', 'chat_send' then #{batch_bodies.inspect} ? #{batch_bodies.inspect}[calls.length - 3] : #{chat.inspect}
            else raise 'unexpected synthetic request'
            end
            response = calls.length == #{status_at.inspect} ? Net::HTTPForbidden.new('1.1', '403', 'Forbidden') : Net::HTTPOK.new('1.1', '200', 'OK')
            response.instance_variable_set(:@read, true)
            response.body = body
            block.call(response) if block
            response
          end
        end
        summary = CliAuthenticatedChatCheck.run(['--live', '--config', #{account.inspect}, '--attempt-dir', #{attempt.inspect}, *#{extra.inspect}])
        retained = defined?(GAME) && GAME.chat.opened?(999)
        cursor = retained && GAME.chat.find { |room| room.id == 999 }.last_message
        puts JSON.generate(summary: summary, calls: calls, starts: starts, config_readers: reads, retained: retained, cursor: cursor, trace: trace, syncs: syncs,
                           polling: defined?(CHAT_ROOMS) ? CHAT_ROOMS.length : 0)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, runner)
      expect(err).not_to include('PRIVATE_EXCEPTION', 'PRIVATE_DISK_ERROR', 'synthetic-password', 'SYNTHETIC_SESSION')
      expect(status.exitstatus).to eq(0)
      expect(out.lines.length).to eq(1)
      yield JSON.parse(out.lines.last), dir if block_given?
      result = JSON.parse(out.lines.last)
      expect(JSON.generate(result['summary'])).not_to include('PRIVATE_EXCEPTION', 'PRIVATE_DISK_ERROR', 'synthetic-password', 'SYNTHETIC_SESSION', '777')
      result
    end
  end

  it 'runs real CLI auth, exact Unicode name check and a single read, retaining the local cursor without polling' do
    result = run_fake do |_result, dir|
      capture = File.read(File.join(dir, 'attempt', 'stdout'))
      expect(capture).not_to include('✘')
      cli = JSON.parse(capture.lines.last)
      expect(cli['commands']).to eq(described_class::COMMANDS.map { |cmd| { 'command' => cmd, 'ok' => true } })
      expect(File.stat(File.join(dir, 'attempt')).mode & 0o777).to eq(0o700)
      %w[stdout stderr reservation.json summary.json].each do |name|
        expect(File.stat(File.join(dir, 'attempt', name)).mode & 0o777).to eq(0o600)
      end
      expect(JSON.parse(File.read(File.join(dir, 'attempt', 'summary.json')))).to eq(_result['summary'])
    end
    expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display]), result['summary'].inspect
    expect(result['summary']).to include('classification' => 'read-complete', 'rpc_count' => 3,
                                       'name_verified' => true, 'message_count' => 1, 'cli_exit' => 0)
    expect(result).to include('retained' => true, 'cursor' => '1000', 'polling' => 0)
    expect(result['starts']).to eq([1, 2, 3])
    expect(result['config_readers']).to eq([File.expand_path('../lib/cli/sandbox.rb', __dir__)])
    expect(result['summary'].keys.sort).to eq(described_class::INITIAL.keys.sort)
    expect(JSON.generate(result['summary'])).not_to include('SYNTHETIC_SESSION', 'synthetic-password', '777', 'Alice', 'hello')
  end

  ['1,0,7,SYNTHETIC_SESSION,4,500', '0,0,7,SYNTHETIC_SESSION'].each do |payload|
    it "accepts minimal-auth SID variant #{payload.split(',').length} fields, first #{payload.split(',').first}" do
      result = run_fake(auth: payload)
      expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display]), result['summary'].inspect
      expect(result['summary']).to include('classification' => 'read-complete', 'rpc_count' => 3,
                                         'name_verified' => true, 'message_count' => 1, 'cli_exit' => 0)
      expect(result).to include('retained' => true, 'cursor' => '1000', 'polling' => 0)
      expect(result['starts']).to eq([1, 2, 3])
      expect(result['config_readers']).to eq([File.expand_path('../lib/cli/sandbox.rb', __dir__)])
      expect(JSON.generate(result['summary'])).not_to include('SYNTHETIC_SESSION', 'synthetic-password', '777')
    end
  end

  it 'counts an empty baseline without inventing a cursor' do
    result = run_fake(chat: '')
    expect(result['summary']).to include('classification' => 'read-complete', 'message_count' => 0)
    expect(result).to include('retained' => true, 'cursor' => '', 'polling' => 0)
  end

  [1, 2, 3].each do |ordinal|
    it "stops a timeout at actual request #{ordinal}, without advancing" do
      result = run_fake(timeout_at: ordinal)
      expect(result['calls'].length).to eq(ordinal)
      expect(result['summary']).to include('classification' => 'transport-timeout', 'rpc_count' => ordinal, 'cli_exit' => 1)
      expect(result['summary']['statuses'].length).to eq(ordinal - 1)
      expect(JSON.generate(result['summary'])).not_to include('PRIVATE_EXCEPTION')
    end
  end

  ['bad', 'Exception,private detail', '0,0,0,,4,500'].each do |payload|
    it "stops malformed auth #{payload.split(',').first.inspect} after one request" do
      result = run_fake(auth: payload)
      expect(result['calls']).to eq(['auth_id_password'])
      expect(result['summary']['classification']).to eq('auth-malformed')
    end
  end

  [1, 2, 3].each do |ordinal|
    it "stops HTTP failure at actual request #{ordinal}" do
      result = run_fake(status_at: ordinal)
      expect(result['calls'].length).to eq(ordinal)
      expect(result['summary']).to include('classification' => 'http-error', 'rpc_count' => ordinal, 'cli_exit' => 1)
      expect(result['summary']['statuses']).to eq([200] * (ordinal - 1) + [403])
    end
  end

  it 'stops malformed profile before reading' do
    result = run_fake(profile_body: 'Exception,private profile')
    expect(result['calls']).to eq(%w[auth_id_password player_get_info])
    expect(result['summary']['cli_exit']).to eq(1)
    expect(result['summary']['name_verified']).to eq(false)
    expect(JSON.generate(result['summary'])).not_to include('private profile')
  end

  it 'rejects a profile for a different identity before reading' do
    result = run_fake(profile_id: 778)
    expect(result['calls']).to eq(%w[auth_id_password player_get_info])
    expect(result['summary']['classification']).to eq('identity-refused')
  end

  ['garbage', 'Exception,secret'].each do |payload|
    it 'stops malformed chat safely after exactly three requests' do
      result = run_fake(chat: payload)
      expect(result['calls'].length).to eq(3)
      expect(result['summary']).to include('classification' => 'cli-failed', 'cli_exit' => 1)
      expect(JSON.generate(result['summary'])).not_to include(payload)
    end
  end

  [{ host: 'invalid.example' }, { port: 80 }, { url: '/forbidden' },
   { version: 1230 }, { id: 0 }, { password: '' }].each do |config|
    it "blocks synthetic config deviation #{config.keys.first} before transport" do
      result = run_fake(config: config)
      expect(result['calls']).to be_empty
      expect(result['starts']).to be_empty
      expect(result['summary']['cli_exit']).to eq(1)
    end
  end

  it 'rejects send/command injection options before loading any config or transport' do
    result = run_fake(extra: ['--message', 'anything'])
    expect(result['calls']).to be_empty
    expect(result['config_readers']).to be_empty
    expect(result['summary']['classification']).to eq('options-refused')
  end

  it 'stops a different name before the World read' do
    result = run_fake(name: 'wrong')
    expect(result['calls']).to eq(%w[auth_id_password player_get_info])
    expect(result['summary']).to include('classification' => 'name-mismatch', 'name_verified' => false)
  end

  describe 'exclusive attempt reservation' do
    it 'refuses duplicate names without reading or changing old files' do
      Dir.mktmpdir('attempt-spec') do |dir|
        path = File.join(dir, 'attempt')
        first = described_class::Attempt.new(path)
        first.out.write('preserve synthetic evidence')
        first.close
        before = File.binread(File.join(path, 'stdout'))
        expect { described_class::Attempt.new(path) }.to raise_error(described_class::Stop, 'existing-attempt-refused')
        expect(File.binread(File.join(path, 'stdout'))).to eq(before)
      end
    end

    it 'reserves each SEND exclusively, preserving a spent reservation on reuse' do
      Dir.mktmpdir('attempt-spec') do |dir|
        attempt = described_class::Attempt.new(File.join(dir, 'attempt'))
        attempt.sync_parent!
        attempt.reserve_send(1)
        reservation = File.join(dir, 'attempt', 'send-1.json')
        before = File.binread(reservation)
        expect(File.stat(reservation).mode & 0o777).to eq(0o600)
        expect { attempt.reserve_send(1) }.to raise_error(described_class::Stop, 'reservation-failed')
        expect(File.binread(reservation)).to eq(before)
        attempt.close
      end
    end

    [:open, :write, :fsync].each do |operation|
      it "refuses #{operation} failure without allowing reservation reuse" do
        Dir.mktmpdir('attempt-spec') do |dir|
          attempt = described_class::Attempt.new(File.join(dir, 'attempt'))
          path = File.join(dir, 'attempt', 'send-1.json')
          if operation == :open
            allow(File).to receive(:open).and_call_original
            allow(File).to receive(:open).with(path, File::WRONLY | File::CREAT | File::EXCL, 0o600).and_raise(IOError)
          else
            allow_any_instance_of(File).to receive(operation).and_raise(IOError)
          end
          expect { attempt.reserve_send(1) }.to raise_error(described_class::Stop, 'reservation-failed')
          expect(File.exist?(path)).to eq(operation != :open)
          attempt.close
        end
      end
    end

    it 'refuses symlink destinations and ancestors' do
      Dir.mktmpdir('attempt-spec') do |dir|
        target = File.join(dir, 'target')
        Dir.mkdir(target, 0o700)
        link = File.join(dir, 'link')
        File.symlink(target, link)
        expect { described_class::Attempt.new(link) }.to raise_error(described_class::Stop)
        expect { described_class::Attempt.new(File.join(link, 'attempt')) }.to raise_error(described_class::Stop, 'attempt-path-invalid')
        expect(Dir.children(target)).to be_empty
      end
    end
  end

  describe 'pre-wire guard' do
    let(:guard) { described_class::HttpGuard.new }
    let(:http) do
      Net::HTTP.new('hackers-1.appspot.com', 443, nil).tap do |client|
        client.use_ssl = true
        client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        client.open_timeout = 10
        client.read_timeout = 15
        client.write_timeout = 10
        client.max_retries = 0
      end
    end
    let(:auth_params) { { 'auth_id_password' => nil, 'id_player' => '777', 'password' => 'fake', 'app_version' => '1229', 'cmd_id' => 'ABCDEFGH' } }

    def request(params)
      Net::HTTP::Get.new('/req.php?' + URI.encode_www_form(params))
    end

    { address: 'other.example', port: 80, use_ssl: false, verify_mode: OpenSSL::SSL::VERIFY_NONE,
      open_timeout: 11, read_timeout: 16, write_timeout: 11, max_retries: 1 }.each do |field, value|
      it "blocks incorrect #{field} before recording a dispatch" do
        allow(http).to receive(field == :use_ssl ? :use_ssl? : field).and_return(value)
        expect { guard.before_request(http, request(auth_params)) }.to raise_error(described_class::Stop, 'transport-refused')
        expect(guard.rpc_count).to eq(0)
      end
    end

    it 'blocks an enabled proxy' do
      allow(http).to receive(:proxy?).and_return(true)
      expect { guard.before_request(http, request(auth_params)) }.to raise_error(described_class::Stop, 'transport-refused')
    end

    it 'blocks sends, rename, creation, catalogs and out-of-order reads' do
      %w[chat_send player_set_name_once player_create get_node_types_and_levels chat_display].each do |rpc|
        params = auth_params.reject { |key, _| key == 'auth_id_password' }.merge(rpc => nil)
        expect { guard.before_request(http, request(params)) }.to raise_error(described_class::Stop, 'rpc-refused')
      end
      expect(guard.rpc_count).to eq(0)
    end

    it 'requires bare auth and chat flags, but preserves profile flag equals encoding' do
      expect { guard.before_request(http, request(auth_params.merge('auth_id_password' => ''))) }.to raise_error(described_class::Stop, 'flag-refused')
      guard.before_request(http, request(auth_params))
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.instance_variable_set(:@read, true)
      response.body = '0,0,0,FAKESID,4,500'
      guard.after_response(response)
      profile = { 'player_get_info' => '', 'id' => '777', 'app_version' => '1229', 'session_id' => 'FAKESID', 'cmd_id' => 'ABCDEFGH' }
      expect { guard.before_request(http, request(profile.merge('id' => '778'))) }.to raise_error(described_class::Stop, 'identity-refused')
      expect { guard.before_request(http, request(profile.merge('session_id' => 'OTHER'))) }.to raise_error(described_class::Stop, 'session-refused')
      guard.before_request(http, request(profile))
      chat = { 'chat_display' => nil, 'room' => '999', 'last_message' => '', 'app_version' => '1229', 'session_id' => 'FAKESID', 'cmd_id' => 'ABCDEFGH' }
      expect { guard.before_request(http, request(chat)) }.to raise_error(described_class::Stop, 'name-unverified')
      guard.instance_variable_set(:@name_verified, true)
      expect { guard.before_request(http, request(chat.merge('chat_display' => ''))) }.to raise_error(described_class::Stop, 'flag-refused')
      expect { guard.before_request(http, request(chat.merge('room' => '1'))) }.to raise_error(described_class::Stop, 'room-refused')
      guard.before_request(http, request(chat))
      expect { guard.before_request(http, request(chat)) }.to raise_error(described_class::Stop, 'rpc-ceiling')
      expect(guard.rpc_count).to eq(3)
    end

    it 'refuses a GET payload before dispatch' do
      raw = request(auth_params)
      raw.body = 'unexpected body'
      expect { guard.before_request(http, raw) }.to raise_error(described_class::Stop, 'destination-refused')
      expect(guard.rpc_count).to eq(0)
    end

    it 'refuses non-GET methods before dispatch' do
      raw = Net::HTTP::Post.new(request(auth_params).path)
      expect { guard.before_request(http, raw) }.to raise_error(described_class::Stop, 'destination-refused')
      expect(guard.rpc_count).to eq(0)
    end

    it 'refuses duplicate parameters, extra parameters and absolute destinations' do
      raw = request(auth_params)
      duplicate = Net::HTTP::Get.new(raw.path + '&id_player=778')
      expect { guard.before_request(http, duplicate) }.to raise_error(described_class::Stop, 'rpc-refused')
      expect { guard.before_request(http, request(auth_params.merge('message' => 'injected'))) }.to raise_error(described_class::Stop, 'rpc-refused')
      absolute = Net::HTTP::Get.new('https://other.example' + raw.path)
      expect { guard.before_request(http, absolute) }.to raise_error(described_class::Stop, 'destination-refused')
      expect(guard.rpc_count).to eq(0)
    end
  end

  describe 'bounded protected CLI batch' do
    def successful_bodies(count = 5)
      ['1000,Alice,hello,55,60,3,999'] + (1..count).flat_map do |index|
        ['', "#{1000 + index},Own,Test codificacion #{index},777,60,3,999"]
      end
    end

    def batch(count: 5, bodies: successful_bodies(count), **options)
      run_fake(extra: ['--send-count', count.to_s], batch_bodies: bodies, **options)
    end

    it 'executes exactly thirteen real CLI RPCs with confirmation before every next wire' do
      result = batch
      expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display] + %w[chat_send chat_display] * 5), result['summary'].inspect
      expect(result['summary']).to include('classification' => 'batch-confirmed', 'confirmed_count' => 5,
                                         'reserved_count' => 5, 'possibly_dispatched_count' => 5)
      expect(result['trace'].select { |entry| entry['rpc'] == 'chat_send' }.map { |entry| entry['text'] }).to eq((1..5).map { |n| "Test codificacion #{n}" })
      expect(result['trace'].all? { |entry| entry.values_at('room_ok', 'owner_ok', 'session_ok').all? }).to be(true)
      expect(result['trace'].drop(3).map { |entry| entry['cursor'] }).to eq((1000..1004).flat_map { |n| [n.to_s, n.to_s] })
      expect(result['config_readers']).to eq([File.expand_path('../lib/cli/sandbox.rb', __dir__)])
      expect(result['polling']).to eq(0)
      expect(JSON.generate(result['summary'])).not_to include('777', 'SYNTHETIC_SESSION', 'synthetic-password', 'Own', 'Test codificacion')
    end

    [1, 2, 3, 4].each do |count|
      it "supports only the exact authorized prefix of #{count} messages" do
        result = batch(count: count)
        expect(result['calls'].length).to eq(3 + 2 * count)
        expect(result['summary']).to include('classification' => 'batch-confirmed', 'confirmed_count' => count)
      end
    end

    %w[0 6 -1 1.0 01 five].each do |count|
      it "refuses count #{count} before CLI config loading or HTTP" do
        result = batch(count: count, bodies: [])
        expect(result['calls']).to be_empty
        expect(result['config_readers']).to be_empty
        expect(result['summary']['classification']).to eq('options-refused')
      end
    end

    [4, 5, 8, 9].each do |ordinal|
      { timeout_at: 'transport-timeout', status_at: 'http-error' }.each do |option, classification|
        it "stops #{classification} at batch wire #{ordinal} with no subsequent RPC" do
          result = batch(**{ option => ordinal })
          expect(result['calls'].length).to eq(ordinal)
          confirmed = (ordinal - 4) / 2
          expect(result['summary']).to include('classification' => classification, 'confirmed_count' => confirmed,
                                             'reserved_count' => confirmed + 1, 'possibly_dispatched_count' => confirmed + 1)
        end
      end
    end

    [3, 4, 5, 8, 9].each do |ordinal|
      ['Exception,private body', 'bad', '1001,Own,text,no,60,3,999', '1001,Own,text,777,60,3,no'].each do |body|
        it "rejects malformed response at wire #{ordinal} before CLI advances" do
          bodies = successful_bodies
          bodies[ordinal - 3] = body
          result = batch(bodies: bodies)
          expect(result['calls'].length).to eq(ordinal)
          expect(result['summary']['classification']).to eq('chat-malformed')
          expect(JSON.generate(result['summary'])).not_to include(body)
        end
      end
    end

    ['', '1001,Other,Test codificacion 1,778,60,3,999', '1001,Own,wrong text,777,60,3,999'].each do |body|
      it 'halts on an absent, wrong-owner or wrong-text read echo' do
        bodies = successful_bodies
        bodies[2] = body
        result = batch(bodies: bodies)
        expect(result['calls'].length).to eq(5)
        expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 0)
      end
    end

    it 'uses validated request room rather than country as publication provenance' do
      bodies = successful_bodies(1)
      bodies[2] = '1001,Own,Test codificacion 1,777,60,3,1'
      result = batch(count: 1, bodies: bodies)
      expect(result['calls'].length).to eq(5)
      # The production aggregate still conflates country with room. Preserve
      # its failure honestly, but never discard the guard's actual evidence.
      expect(result['summary']).to include('classification' => 'cli-failed', 'cli_exit' => 1, 'confirmed_count' => 1)
    end

    it 'rejects baseline identity reuse even with changed name, level, rank or country' do
      bodies = successful_bodies
      bodies[0] = '1000,Own,Test codificacion 1,777,60,3,999'
      bodies[2] = '1000,Renamed,Test codificacion 1,777,70,4,1'
      result = batch(bodies: bodies)
      expect(result['calls'].length).to eq(5)
      expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 0)
    end

    it 'remembers early future-message echoes across all observed responses' do
      bodies = successful_bodies
      bodies[1] = '1002,Own,Test codificacion 2,777,60,3,999'
      result = batch(bodies: bodies)
      expect(result['calls'].length).to eq(7)
      expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 1)
    end

    it 'never confirms from SEND and preserves its consumed cursor on the required empty READ' do
      bodies = successful_bodies
      bodies[1] = bodies[2]
      bodies[2] = ''
      result = batch(bodies: bodies)
      expect(result['calls'].length).to eq(5)
      expect(result['trace'][4]['cursor']).to eq('1001')
      expect(result['cursor']).to eq('1001')
      expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 0)
    end

    it 'refuses per-send directory sync failure before the first SEND' do
      result = batch(disk_failure: 'send-directory')
      expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display])
      expect(result['summary']).to include('classification' => 'reservation-failed', 'possibly_dispatched_count' => 0)
    end

    it 'rejects a future echo already present in the baseline' do
      bodies = successful_bodies
      bodies[0] = bodies[4]
      result = batch(bodies: bodies)
      expect(result['calls'].length).to eq(7)
      expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 1)
    end

    it 'refuses an incomplete ledger write before dispatch, not merely after the batch' do
      result = batch(disk_failure: 'short-write')
      expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display])
      expect(result['summary']).to include('classification' => 'reservation-failed', 'possibly_dispatched_count' => 0)
    end

    ['send-1.json', 'send-3.json'].each do |filename|
      it "stops #{filename} durability failure before its mutative wire" do
        result = batch(disk_failure: filename)
        index = filename[/\d+/].to_i
        expect(result['calls'].length).to eq(3 + 2 * (index - 1))
        expect(result['summary']).to include('classification' => 'reservation-failed', 'confirmed_count' => index - 1,
                                           'reserved_count' => index - 1, 'possibly_dispatched_count' => index - 1)
      end
    end

    it 'halts at an unconfirmed first read instead of issuing the next mutative wire' do
      bodies = successful_bodies
      bodies[2] = ''
      result = batch(bodies: bodies)
      expect(result['calls']).to eq(%w[auth_id_password player_get_info chat_display chat_send chat_display]), result['summary'].inspect
      expect(result['summary']).to include('classification' => 'echo-unconfirmed', 'confirmed_count' => 0)
    end
  end

  it 'does not install network hooks for default, help or invalid options' do
    expect(Net::HTTP).not_to receive(:new)
    expect(described_class.run([])['classification']).to eq('offline')
    expect(described_class.run(['--help'])['classification']).to eq('offline')
    expect(described_class.run(['--live'])['classification']).to eq('options-refused')
  end
end
