#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-CLI live verification helper for the already-authorized World 999
# current-prefix chat check. Default mode is an offline self-test; only
# --live may read the private account config or touch the network.

require 'fileutils'
require 'json'
require 'net/http'
require 'openssl'
require 'stringio'
require 'tmpdir'
require 'time'
require 'uri'
require 'zlib'

require_relative '../lib/hackers/serializer'

class CliCurrentPrefixCheck
  EXPECTED_NAME = "[ff0000]βℓąȼЌhąţhąȼЌ"
  MESSAGE = 'Test'
  ROOM = '999'
  HOST = 'hackers-1.appspot.com'
  PORT = 443
  PATH = '/req.php'
  VERSION = '1229'
  ACCOUNT_DIR = File.expand_path('~/.local/share/ta-hackers-toolchain/accounts/backend-functional-test')
  CONFIG_PATH = File.join(ACCOUNT_DIR, 'credentials.json')
  LEDGER_PATH = File.join(ACCOUNT_DIR, 'cli-current-prefix-test-world999.json')
  OLD_LEDGER_PATH = File.join(ACCOUNT_DIR, 'cli-priority-attempt.json')
  STDOUT_PATH = File.join(ACCOUNT_DIR, 'cli-current-prefix-test-world999.stdout')
  STDERR_PATH = File.join(ACCOUNT_DIR, 'cli-current-prefix-test-world999.stderr')
  SANDBOX_PATH = File.expand_path('../bin/sandbox', __dir__)

  COMMANDS = [
    'connect',
    "name --expect #{EXPECTED_NAME}",
    "chat say #{ROOM} #{MESSAGE}",
    "chat read #{ROOM}"
  ].freeze

  SAFE_INITIAL = {
    'tool' => 'cli_current_prefix_check',
    'classification' => 'started',
    'send_attempted' => false,
    'own_message_seen' => false,
    'chat_message_count' => 0,
    'rpc_count' => 0,
    'statuses' => [],
    'stop' => nil,
    'exit' => nil
  }.freeze

  class Stop < Exception
    attr_reader :classification

    def initialize(classification, message = classification)
      @classification = classification
      super(message)
    end
  end

  class Ledger
    attr_reader :path, :data

    def initialize(path)
      @path = path
      @data = SAFE_INITIAL.merge('created_at' => Time.now.utc.iso8601)
    end

    def create_exclusive!
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(@path, flags, 0o600) { |file| file.write(JSON.pretty_generate(@data)) }
    rescue Errno::EEXIST
      raise Stop.new('existing-ledger-refused', 'exclusive ledger already exists')
    end

    def update!(changes)
      @data.merge!(changes)
      File.open(@path, File::WRONLY | File::TRUNC, 0o600) { |file| file.write(JSON.pretty_generate(@data)) }
    end
  end

  class HttpGuard
    RPC_ORDER = %w[auth_id_password player_get_info chat_send chat_display].freeze

    attr_reader :rpc_count, :statuses, :send_attempted

    def initialize(ledger:, account_id:)
      @ledger = ledger
      @account_id = account_id.to_s
      @rpc_count = 0
      @statuses = []
      @send_attempted = false
      @auth_session_id = nil
      @current_rpc = nil
      @name_checked = false
      @installed = false
    end

    def install!
      return if @installed

      guard = self
      net_http_singleton = class << Net::HTTP; self; end
      @original_new = Net::HTTP.method(:new)
      @original_request = Net::HTTP.instance_method(:request)

      net_http_singleton.send(:define_method, :new) do |address, port = nil, *_args|
        # Force no proxy in this guarded run; the CLI source must not inherit
        # ambient proxy settings while verifying this account. Also pin peer
        # verification on the client object before the real CLI starts it.
        client = guard.send(:original_new).call(address, port, nil)
        client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        client
      end

      Net::HTTP.send(:define_method, :request) do |request, body = nil, &block|
        guard.before_request(self, request)
        response = guard.send(:original_request).bind_call(self, request, body, &block)
        guard.after_response(response)
        response
      end
      @installed = true
    end

    def uninstall!
      return unless @installed

      original_new = @original_new
      original_request = @original_request
      (class << Net::HTTP; self; end).send(:define_method, :new) do |*args, &block|
        original_new.call(*args, &block)
      end
      Net::HTTP.send(:define_method, :request, original_request)
      @installed = false
    end

    protected

    attr_reader :original_new, :original_request

    public

    def before_request(http, request)
      validate_transport!(http, request)
      params = URI.decode_www_form(URI(request.path).query.to_s).to_h
      rpc = classify_rpc(params)
      expected_rpc = RPC_ORDER[@rpc_count]
      raise Stop.new('unexpected-rpc-order', "expected #{expected_rpc}, got #{rpc}") unless rpc == expected_rpc

      validate_params!(rpc, params)
      @current_rpc = rpc
      @rpc_count += 1
      if rpc == 'chat_send'
        @send_attempted = true
        @ledger.update!('send_attempted' => true, 'rpc_count' => @rpc_count, 'classification' => 'send-attempted')
      else
        @ledger.update!('rpc_count' => @rpc_count)
      end
    end

    def after_response(response)
      status = response.code.to_i
      @statuses << status
      @ledger.update!('statuses' => @statuses, 'rpc_count' => @rpc_count)
      raise Stop.new('http-non-200', "HTTP #{status}") unless status == 200

      body = response_body(response)
      case @current_rpc
      when 'auth_id_password'
        @auth_session_id = extract_auth_session_id(body)
      when 'player_get_info'
        validate_profile_identity!(body)
      end
    end

    private

    def response_body(response)
      body = response.body.to_s
      case response['Content-Encoding'].to_s.strip.downcase
      when '', 'identity'
        body.force_encoding('UTF-8')
      when 'gzip'
        Zlib::GzipReader.new(StringIO.new(body)).read.force_encoding('UTF-8')
      else
        raise Stop.new('unsupported-content-encoding')
      end
    rescue Zlib::GzipFile::Error
      raise Stop.new('invalid-gzip-response')
    end

    def validate_transport!(http, request)
      raise Stop.new('bad-host') unless http.address == HOST
      raise Stop.new('bad-port') unless http.port.to_i == PORT
      raise Stop.new('bad-method') unless request.method == 'GET'
      raise Stop.new('bad-path') unless URI(request.path).path == PATH
      raise Stop.new('tls-disabled') unless http.use_ssl?
      raise Stop.new('tls-verify-peer-disabled') unless http.verify_mode == OpenSSL::SSL::VERIFY_PEER
      raise Stop.new('proxy-enabled') if http.proxy?
      raise Stop.new('bad-open-timeout') unless http.open_timeout == 10
      raise Stop.new('bad-read-timeout') unless http.read_timeout == 15
      raise Stop.new('bad-write-timeout') unless http.write_timeout == 10
      raise Stop.new('bad-retry-count') unless http.max_retries == 0
      raise Stop.new('too-many-rpcs') if @rpc_count >= RPC_ORDER.length
    end

    def classify_rpc(params)
      matches = RPC_ORDER.select { |key| params.key?(key) }
      raise Stop.new('unknown-rpc') unless matches.length == 1

      matches.first
    end

    def validate_params!(rpc, params)
      raise Stop.new('bad-version') unless params['app_version'] == VERSION

      case rpc
      when 'auth_id_password'
        raise Stop.new('bad-auth-account') unless params['id_player'] == @account_id
        raise Stop.new('auth-has-session') if params.key?('session_id')
      when 'player_get_info'
        require_bound_session!(params)
        raise Stop.new('bad-info-account') unless params['id'] == @account_id
      when 'chat_send'
        require_bound_session!(params)
        raise Stop.new('send-before-name-check') unless @name_checked
        raise Stop.new('bad-send-account') unless params['id_player'] == @account_id
        raise Stop.new('bad-room') unless params['room'] == ROOM
        raise Stop.new('bad-message') unless params['message'] == MESSAGE
      when 'chat_display'
        require_bound_session!(params)
        raise Stop.new('bad-room') unless params['room'] == ROOM
      end
    end

    def require_bound_session!(params)
      sid = params['session_id'].to_s
      raise Stop.new('missing-session') if sid.empty?
      raise Stop.new('session-not-bound') if @auth_session_id.to_s.empty?
      raise Stop.new('session-mismatch') unless sid == @auth_session_id
    end

    def extract_auth_session_id(body)
      sid = Hackers::Serializer.parseData(body).dig(0, 0, 3).to_s
      raise Stop.new('auth-session-missing') if sid.empty?

      sid
    end

    def validate_profile_identity!(body)
      profile = Hackers::Serializer::Profile.new(body).parse(0, 0)
      raise Stop.new('info-identity-mismatch') unless profile.id.to_s == @account_id
      raise Stop.new('name-mismatch') unless profile.name == EXPECTED_NAME

      @name_checked = true
    rescue Hackers::Serializer::ParserError
      raise Stop.new('invalid-info-response')
    end
  end

  def self.run(argv)
    new.run(argv)
  end

  def run(argv)
    if argv.include?('--live')
      return live
    end

    self_test
  end

  def live
    ledger = nil
    ledger_created = false
    guard = nil
    stdout_original = nil
    stderr_original = nil
    stdout_capture = nil
    stderr_capture = nil
    exit_code = 1
    summary = SAFE_INITIAL.merge('classification' => 'unknown')

    begin
      ensure_account_dir!
      account_id = read_account_id!
      ledger = Ledger.new(LEDGER_PATH)
      ledger.create_exclusive!
      ledger_created = true
      secure_private_file(STDOUT_PATH)
      secure_private_file(STDERR_PATH)

      guard = HttpGuard.new(ledger: ledger, account_id: account_id)
      summary.merge!(
        'ledger' => File.basename(LEDGER_PATH),
        'stdout_capture' => File.basename(STDOUT_PATH),
        'stderr_capture' => File.basename(STDERR_PATH),
        'old_ledger_preserved' => File.exist?(OLD_LEDGER_PATH)
      )

      guard.install!
      stdout_original = $stdout
      stderr_original = $stderr
      File.open(STDOUT_PATH, File::WRONLY | File::TRUNC, 0o600) do |out|
        File.open(STDERR_PATH, File::WRONLY | File::TRUNC, 0o600) do |err|
          stdout_capture = out
          stderr_capture = err
          $stdout = stdout_capture
          $stderr = stderr_capture
          begin
            CLI_RESULTS.clear if defined?(CLI_RESULTS) && CLI_RESULTS.respond_to?(:clear)
            reset_cli_batch_state!
            ARGV.replace(['-m', '-c', CONFIG_PATH, *COMMANDS.flat_map { |cmd| ['-e', cmd] }, '--json'])
            load SANDBOX_PATH
            exit_code = 0
          rescue SystemExit => e
            exit_code = e.status || 0
          rescue Stop => e
            summary['stop'] = e.classification
            summary['classification'] = e.classification
            exit_code = 1
          rescue StandardError => e
            summary['stop'] = e.class.to_s
            summary['classification'] = 'exception-before-complete'
            exit_code = 1
          ensure
            $stdout = stdout_original if stdout_original
            $stderr = stderr_original if stderr_original
          end
        end
      end
    rescue Stop => e
      summary['classification'] = e.classification
      summary['stop'] = e.classification
      exit_code = 1
    ensure
      guard&.uninstall!
      $stdout = stdout_original if stdout_original && $stdout.equal?(stdout_capture)
      $stderr = stderr_original if stderr_original && $stderr.equal?(stderr_capture)
    end

    if ledger_created
      cli_summary = parse_cli_summary(STDOUT_PATH)
      final = summary.merge(
        'exit' => exit_code,
        'rpc_count' => guard&.rpc_count.to_i,
        'statuses' => guard&.statuses || [],
        'send_attempted' => guard&.send_attempted == true,
        'own_message_seen' => cli_summary.fetch('own_message_seen', false),
        'chat_message_count' => cli_summary.fetch('chat_message_count', 0)
      )
      final['classification'] = classify_final(final, cli_summary)
      final['stop'] ||= final['classification'] unless final['classification'] == 'completed-confirmed'
      ledger.update!(final)
      puts(JSON.generate(safe_public(final)))
      return final['classification'] == 'completed-confirmed' ? 0 : 1
    end

    puts(JSON.generate(safe_public(summary.merge('exit' => exit_code))))
    1
  end

  def reset_cli_batch_state!
    Object.constants.grep(/\A(?:CLI_RESULTS|CONTEXT_|LIB_DIR|BASE_DIR|DATA_DIR|CONFIGS_DIR|DEFAULT_CONFIG|CONFIG_EXT|COUNTRIES_FILE|BANNER|MINIMAL_CONNECT|GAME|SHELL|LOGGER)/).each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    $LOADED_FEATURES.reject! { |feature| feature.match?(%r{/lib/cli(?:\.rb|/)}) }
  end

  def ensure_account_dir!
    stat = File.stat(ACCOUNT_DIR)
    raise Stop.new('account-dir-not-private') unless stat.directory? && (stat.mode & 0o777) == 0o700
    raise Stop.new('missing-config') unless File.file?(CONFIG_PATH)
  end

  def read_account_id!
    data = JSON.parse(File.read(CONFIG_PATH))
    id = data.fetch('id').to_s
    raise Stop.new('missing-account-id') if id.empty?

    id
  rescue JSON::ParserError, KeyError
    raise Stop.new('invalid-config')
  end

  def secure_private_file(path)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |_file| }
  end

  def parse_cli_summary(path)
    return {} unless path && File.file?(path)

    File.readlines(path, chomp: true).reverse_each do |line|
      stripped = line.strip
      next unless stripped.start_with?('{') && stripped.end_with?('}')

      parsed = JSON.parse(stripped)
      return parsed if parsed.is_a?(Hash) && parsed.key?('own_message_seen')
    rescue JSON::ParserError
      next
    end
    {}
  end

  def classify_final(final, cli_summary)
    return final['classification'] if final['classification'] && final['classification'] != 'unknown'
    return 'completed-confirmed' if final['exit'] == 0 && final['send_attempted'] && cli_summary['own_message_seen'] == true
    return 'send-attempted-unconfirmed' if final['send_attempted']

    'stopped-before-send'
  end

  def safe_public(final)
    final.slice('classification', 'send_attempted', 'own_message_seen', 'chat_message_count', 'rpc_count', 'statuses', 'exit', 'stop')
  end

  def self_test
    tests = []
    tests << test_offline_success
    tests << test_forbidden_rename
    tests << test_order_guard
    tests << test_bad_message_guard
    tests << test_fifth_rpc_guard
    tests << test_changed_session_refused
    tests << test_uncertain_send_evidence
    tests << test_real_cli_name_mismatch_stops_send
    tests << test_real_cli_success_exactly_four
    tests << test_existing_ledger_refusal

    failed = tests.reject { |result| result[:ok] }
    result = {
      mode: 'self-test',
      ok: failed.empty?,
      tests: tests
    }
    puts(JSON.generate(result))
    failed.empty? ? 0 : 1
  end

  def test_offline_success
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42')
      http = fake_http
      successful_requests.each do |request, response_body|
        guard.before_request(http, request)
        guard.after_response(fake_response(200, response_body))
      end
      pass('offline success exact four') { guard.rpc_count == 4 && guard.send_attempted && ledger.data['statuses'] == [200, 200, 200, 200] }
    end
  end

  def test_forbidden_rename
    assert_stop('forbidden rename', 'unknown-rpc') do |guard, http|
      guard.before_request(http, query('player_set_name_once' => '', 'id' => '42', 'name' => 'x', 'session_id' => 'sid', 'app_version' => VERSION))
    end
  end

  def test_order_guard
    assert_stop('order guard', 'unexpected-rpc-order') do |guard, http|
      guard.before_request(http, query('player_get_info' => '', 'id' => '42', 'session_id' => 'sid', 'app_version' => VERSION))
    end
  end

  def test_bad_message_guard
    assert_stop('bad Test guard', 'bad-message') do |guard, http|
      advance_auth_and_info(guard, http)
      guard.before_request(http, query('chat_send' => '', 'room' => ROOM, 'message' => 'Test!', 'id_player' => '42', 'session_id' => 'sid', 'app_version' => VERSION))
    end
  end

  def test_fifth_rpc_guard
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42')
      http = fake_http
      successful_requests.each { |request, body| guard.before_request(http, request); guard.after_response(fake_response(200, body)) }
      begin
        guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'session_id' => 'sid', 'app_version' => VERSION))
      rescue Stop => e
        return pass('fifth RPC guard') { e.classification == 'too-many-rpcs' }
      end
      pass('fifth RPC guard') { false }
    end
  end

  def test_changed_session_refused
    assert_stop('changed SID refused', 'session-mismatch') do |guard, http|
      guard.before_request(http, query('auth_id_password' => nil, 'id_player' => '42', 'password' => 'secret', 'app_version' => VERSION))
      guard.after_response(fake_response(200, auth_response('sid')))
      guard.before_request(http, query('player_get_info' => '', 'id' => '42', 'session_id' => 'changed', 'app_version' => VERSION))
    end
  end

  def test_uncertain_send_evidence
    result = offline_real_cli(profile_name: EXPECTED_NAME, chat_own: false)
    pass('uncertain send evidence') do
      result[:exit] == 1 && result[:public]['classification'] == 'send-attempted-unconfirmed' &&
        result[:public]['send_attempted'] == true && result[:public]['own_message_seen'] == false &&
        result[:calls] == %w[auth_id_password player_get_info chat_send chat_display]
    end
  end

  def test_real_cli_name_mismatch_stops_send
    result = offline_real_cli(profile_name: 'Mismatch')
    pass('real CLI name mismatch stops send') do
      result[:exit] == 1 && result[:public]['classification'] == 'name-mismatch' &&
        result[:public]['rpc_count'] == 2 && result[:public]['send_attempted'] == false &&
        result[:calls] == %w[auth_id_password player_get_info]
    end
  end

  def test_real_cli_success_exactly_four
    result = offline_real_cli(profile_name: EXPECTED_NAME)
    pass('real CLI success exactly four') do
      result[:exit] == 0 && result[:public]['classification'] == 'completed-confirmed' &&
        result[:public]['rpc_count'] == 4 && result[:public]['send_attempted'] == true &&
        result[:public]['own_message_seen'] == true &&
        result[:calls] == %w[auth_id_password player_get_info chat_send chat_display]
    end
  end

  def test_existing_ledger_refusal
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'ledger.json')
      File.write(path, '{}')
      ledger = Ledger.new(path)
      begin
        ledger.create_exclusive!
      rescue Stop => e
        return pass('existing ledger refusal') { e.classification == 'existing-ledger-refused' }
      end
      pass('existing ledger refusal') { false }
    end
  end

  def assert_stop(name, classification)
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42')
      yield guard, fake_http
      pass(name) { false }
    rescue Stop => e
      pass(name) { e.classification == classification }
    end
  end

  def advance_auth_and_info(guard, http)
    guard.before_request(http, query('auth_id_password' => nil, 'id_player' => '42', 'password' => 'secret', 'app_version' => VERSION))
    guard.after_response(fake_response(200, auth_response('sid')))
    guard.before_request(http, query('player_get_info' => '', 'id' => '42', 'session_id' => 'sid', 'app_version' => VERSION))
    guard.after_response(fake_response(200, profile_response(EXPECTED_NAME)))
  end

  def successful_requests
    [
      [query('auth_id_password' => nil, 'id_player' => '42', 'password' => 'secret', 'app_version' => VERSION), auth_response('sid')],
      [query('player_get_info' => '', 'id' => '42', 'session_id' => 'sid', 'app_version' => VERSION), profile_response(EXPECTED_NAME)],
      [query('chat_send' => '', 'room' => ROOM, 'message' => MESSAGE, 'id_player' => '42', 'session_id' => 'sid', 'app_version' => VERSION), chat_response],
      [query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION), chat_response]
    ]
  end

  def offline_real_cli(profile_name:, chat_own: true)
    Dir.mktmpdir do |dir|
      account_dir = File.join(dir, 'account')
      Dir.mkdir(account_dir, 0o700)
      config_path = File.join(account_dir, 'credentials.json')
      ledger_path = File.join(account_dir, 'ledger.json')
      stdout_path = File.join(account_dir, 'stdout.log')
      stderr_path = File.join(account_dir, 'stderr.log')
      old_ledger_path = File.join(account_dir, 'old-ledger.json')
      File.write(config_path, JSON.generate('id' => '42', 'password' => 'secret'))
      calls = []
      install_offline_http_stub(calls, profile_name, chat_own)
      begin
        with_constants(
          'ACCOUNT_DIR' => account_dir,
          'CONFIG_PATH' => config_path,
          'LEDGER_PATH' => ledger_path,
          'OLD_LEDGER_PATH' => old_ledger_path,
          'STDOUT_PATH' => stdout_path,
          'STDERR_PATH' => stderr_path
        ) do
          output = capture_stdout { @offline_exit = live }
          public = JSON.parse(output.lines.last.to_s)
          return { exit: @offline_exit, public: public, calls: calls }
        end
      ensure
        uninstall_offline_http_stub
      end
    end
  end

  def install_offline_http_stub(calls, profile_name, chat_own)
    @offline_original_request = Net::HTTP.instance_method(:request)
    @offline_original_start = Net::HTTP.instance_method(:start)
    @offline_original_started = Net::HTTP.instance_method(:started?)
    Net::HTTP.send(:define_method, :started?) { false }
    Net::HTTP.send(:define_method, :start) { |&block| block ? block.call(self) : self }
    Net::HTTP.send(:define_method, :request) do |request, *_args, &block|
      params = URI.decode_www_form(URI(request.path).query.to_s).to_h
      rpc = CliCurrentPrefixCheck::HttpGuard::RPC_ORDER.detect { |key| params.key?(key) }
      calls << rpc
      body = case rpc
             when 'auth_id_password' then CliCurrentPrefixCheck.new.auth_response('sid')
             when 'player_get_info' then CliCurrentPrefixCheck.new.profile_response(profile_name)
             when 'chat_send', 'chat_display' then CliCurrentPrefixCheck.new.chat_response(own: chat_own)
             else ''
             end
      response = CliCurrentPrefixCheck.new.http_ok(body)
      block.call(response) if block
      response
    end
  end

  def uninstall_offline_http_stub
    Net::HTTP.send(:define_method, :request, @offline_original_request) if @offline_original_request
    Net::HTTP.send(:define_method, :start, @offline_original_start) if @offline_original_start
    Net::HTTP.send(:define_method, :started?, @offline_original_started) if @offline_original_started
  end

  def with_constants(values)
    originals = values.each_with_object({}) { |(name, _value), out| out[name] = nil }
    values.each_key do |name|
      originals[name] = self.class.const_get(name)
      self.class.send(:remove_const, name)
    end
    values.each { |name, value| self.class.const_set(name, value) }
    yield
  ensure
    values.each_key { |name| self.class.send(:remove_const, name) if self.class.const_defined?(name, false) }
    originals.each { |name, value| self.class.const_set(name, value) }
  end

  def capture_stdout
    original = $stdout
    io = StringIO.new
    $stdout = io
    yield
    io.string
  ensure
    $stdout = original
  end

  def with_temp_ledger
    Dir.mktmpdir do |dir|
      ledger = Ledger.new(File.join(dir, 'ledger.json'))
      ledger.create_exclusive!
      yield ledger
    end
  end

  def pass(name)
    { name: name, ok: yield }
  rescue StandardError => e
    { name: name, ok: false, error: e.class.to_s, message: e.message }
  end

  FakeRequest = Struct.new(:path, :method)
  FakeResponse = Struct.new(:code, :body) do
    def [](_header) = nil
  end

  def query(params)
    FakeRequest.new("#{PATH}?#{URI.encode_www_form(params)}", 'GET')
  end

  def fake_response(code, body = '')
    FakeResponse.new(code.to_s, body)
  end

  def auth_response(sid)
    ['0', '0', '0', sid, '1', '1'].join(',')
  end

  def profile_response(name, id = '42')
    [id, name, '0', '0', '0', '0', '0', '0', '0', '1', '0', '0', '0', '0', '0'].join(',')
  end

  def chat_response(own: true)
    id = own ? '42' : '7'
    message = own ? MESSAGE : 'Other'
    ['2024-01-01T00:00:00Z', EXPECTED_NAME, message, id, '1', '1', ROOM].join(',')
  end

  def http_ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    response
  end

  def fake_http
    Struct.new(:address, :port, :open_timeout, :read_timeout, :write_timeout, :max_retries) do
      def use_ssl? = true
      def verify_mode = OpenSSL::SSL::VERIFY_PEER
      def proxy? = false
    end.new(HOST, PORT, 10, 15, 10, 0)
  end
end

unless Hash.method_defined?(:slice)
  class Hash
    def slice(*keys)
      keys.each_with_object({}) { |key, out| out[key] = self[key] if key?(key) }
    end
  end
end

exit(CliCurrentPrefixCheck.run(ARGV))
