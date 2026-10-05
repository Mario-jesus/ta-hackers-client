#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-CLI live diagnostic for the authorized World 999 chat-send path.
# Default mode is an offline self-test; only --live reads the private config or
# touches the network. Adapted only from scripts/cli_current_prefix_check.rb.

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

class CliChatDiagnosticCheck
  EXPECTED_NAME = "[ff0000]βℓąȼЌhąţhąȼЌ"
  MESSAGE = 'Test diagnostico'
  ATTEMPT4_MESSAGE = 'Test protocolo'
  ATTEMPT5_MESSAGE = 'Test codificacion'
  ROOM = '999'
  HOST = 'hackers-1.appspot.com'
  PORT = 443
  PATH = '/req.php'
  VERSION = '1229'
  ACCOUNT_DIR = File.expand_path('~/.local/share/ta-hackers-toolchain/accounts/backend-functional-test')
  CONFIG_PATH = File.join(ACCOUNT_DIR, 'credentials.json')
  LEDGER_PATH = File.join(ACCOUNT_DIR, 'cli-chat-diagnostic-world999.json')
  STDOUT_PATH = File.join(ACCOUNT_DIR, 'cli-chat-diagnostic-world999.stdout')
  STDERR_PATH = File.join(ACCOUNT_DIR, 'cli-chat-diagnostic-world999.stderr')
  SEND_RAW_PATH = File.join(ACCOUNT_DIR, 'cli-chat-diagnostic-world999.send-response.raw')
  SEND_HEADERS_PATH = File.join(ACCOUNT_DIR, 'cli-chat-diagnostic-world999.send-response.headers.json')
  SANDBOX_PATH = File.expand_path('../bin/sandbox', __dir__)
  BODY_CAPTURE_LIMIT = 1_000_000
  ATTEMPTS = %w[1 2 3 4 5 6].freeze
  TRANSPORT_EXCEPTION_ALLOWLIST = [
    'Net::ReadTimeout',
    'Net::OpenTimeout',
    'Net::WriteTimeout',
    'OpenSSL::SSL::SSLError',
    'EOFError',
    'IOError'
  ].freeze

  def commands_for_attempt(attempt)
    message = message_for_attempt(attempt)
    [
      'connect',
      "name --expect #{EXPECTED_NAME}",
      'chat list',
      "chat read #{ROOM}",
      "chat say #{ROOM} #{message}",
      "chat read #{ROOM}"
    ]
  end
  READ_ONLY_COMMANDS = [
    'connect',
    "name --expect #{EXPECTED_NAME}",
    'chat list',
    "chat read #{ROOM}"
  ].freeze

  SAFE_INITIAL = {
    'tool' => 'cli_chat_diagnostic_check',
    'classification' => 'started',
    'send_attempted' => false,
    'own_message_seen' => false,
    'chat_publication_status' => nil,
    'chat_message_count' => 0,
    'rpc_count' => 0,
    'statuses' => [],
    'checks' => [],
    'send_response' => nil,
    'transport_failure' => nil,
    'responses' => {},
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
      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.pretty_generate(@data)) }
    rescue Errno::EEXIST
      raise Stop.new('existing-ledger-refused', 'exclusive ledger already exists')
    end
    def update!(changes)
      @data.merge!(changes)
      File.open(@path, File::WRONLY | File::TRUNC, 0o600) { |f| f.write(JSON.pretty_generate(@data)) }
    end
  end

  class HttpGuard
    RPC_ORDER = %w[auth_id_password player_get_info chat_display chat_send chat_display].freeze
    READ_ONLY_RPC_ORDER = %w[auth_id_password player_get_info chat_display].freeze
    SAFE_FIELDS = %w[auth_id_password player_get_info chat_display chat_send id id_player password room last_message message app_version session_id cmd_id].freeze
    FORBIDDEN_RPC_KEYS = %w[player_set_name player_set_name_once tutorial_player_set_name player_create auth_pair_fb auth_unpair_fb auth_pair_google auth_google_new auth_fb auth].freeze

    attr_reader :rpc_count, :statuses, :send_attempted, :checks, :responses, :own_message_seen_by_response, :chat_publication_status_by_response

    def initialize(ledger:, account_id:, private_paths: {}, read_only: false, expected_message: MESSAGE)
      @ledger = ledger
      @account_id = account_id.to_s
      @private_paths = private_paths
      @read_only = read_only == true
      @expected_message = expected_message.to_s
      @rpc_count = 0
      @statuses = []
      @checks = []
      @send_attempted = false
      @auth_session_id = nil
      @current_rpc = nil
      @name_checked = false
      @prior_room_last_message = nil
      @installed = false
      @responses = {}
      @own_message_seen_by_response = false
      @chat_publication_status_by_response = nil
    end

    def install!
      return if @installed
      guard = self
      @original_new = Net::HTTP.method(:new)
      @original_request = Net::HTTP.instance_method(:request)
      (class << Net::HTTP; self; end).send(:define_method, :new) do |address, port = nil, *_args|
        client = guard.send(:original_new).call(address, port, nil)
        client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        client
      end
      Net::HTTP.send(:define_method, :request) do |request, body = nil, &block|
        guard.before_request(self, request)
        begin
          response = guard.send(:original_request).bind_call(self, request, body, &block)
        rescue StandardError => e
          guard.capture_transport_failure!(e)
          raise
        end
        guard.after_response(response)
        response
      end
      @installed = true
    end

    def uninstall!
      return unless @installed
      original_new = @original_new
      original_request = @original_request
      (class << Net::HTTP; self; end).send(:define_method, :new) { |*args, &block| original_new.call(*args, &block) }
      Net::HTTP.send(:define_method, :request, original_request)
      @installed = false
    end

    protected
    attr_reader :original_new, :original_request
    public

    def before_request(http, request)
      validate_transport!(http, request)
      pairs = URI.decode_www_form(URI(request.path).query.to_s)
      params = pairs.to_h
      validate_pairs!(pairs)
      rpc = classify_rpc(params)
      ordinal = @rpc_count + 1
      raise Stop.new('read-only-send-forbidden') if @read_only && rpc == 'chat_send'
      expected_order = @read_only ? READ_ONLY_RPC_ORDER : RPC_ORDER
      raise Stop.new('unexpected-rpc-order', "expected #{expected_order[@rpc_count]}, got #{rpc}") unless rpc == expected_order[@rpc_count]
      raise Stop.new('display-ordinal-forbidden') if rpc == 'chat_display' && !(@read_only ? [3] : [3, 5]).include?(ordinal)
      validate_params!(rpc, params, ordinal)
      @current_rpc = rpc
      @rpc_count = ordinal
      if rpc == 'chat_send'
        @send_attempted = true
        @ledger.update!('send_attempted' => true, 'rpc_count' => @rpc_count, 'classification' => 'send-attempted', 'checks' => @checks)
      else
        @ledger.update!('rpc_count' => @rpc_count, 'checks' => @checks)
      end
    end

    def after_response(response)
      status = response.code.to_i
      @statuses << status
      @ledger.update!('statuses' => @statuses, 'rpc_count' => @rpc_count)
      body = response_body(response)
      capture_response(response, body, @current_rpc)
      capture_send_response(response, body) if @current_rpc == 'chat_send' && !@read_only
      raise Stop.new('http-non-200', "HTTP #{status}") unless status == 200

      case @current_rpc
      when 'auth_id_password'
        @auth_session_id = extract_auth_session_id(body)
      when 'player_get_info'
        validate_profile_identity!(body)
        open_room_locally!
      when 'chat_display'
        if @rpc_count == 3
          validate_chat_body_or_stop!(body, 'first-read')
          @prior_room_last_message = last_timestamp_from_chat_body(body)
          @checks << 'first_read_cursor_captured_from_response'
          @ledger.update!('checks' => @checks)
        else
          update_publication_from_chat_body!(body)
        end
      when 'chat_send'
        sent_last = last_timestamp_from_chat_body(body)
        @prior_room_last_message = sent_last unless sent_last.empty?
        @ledger.update!('checks' => @checks)
      end
    end

    def capture_transport_failure!(error)
      safe_class = safe_transport_exception_class(error)
      failure = {
        'operation' => @current_rpc.to_s.empty? ? 'unknown' : @current_rpc,
        'ordinal' => @rpc_count,
        'exception_class' => safe_class,
        'transport_error' => safe_class == 'transporterror' ? 'transporterror' : 'allowlisted'
      }
      @ledger.update!('classification' => 'transport-failure', 'stop' => 'transport-failure', 'transport_failure' => failure, 'rpc_count' => @rpc_count, 'statuses' => @statuses, 'send_attempted' => @send_attempted)
    end

    private

    def safe_transport_exception_class(error)
      name = error.class.to_s
      return name if TRANSPORT_EXCEPTION_ALLOWLIST.include?(name)
      return name if name.start_with?('Errno::')
      'transporterror'
    end

    def response_body(response)
      body = response.body.to_s.dup
      case response['Content-Encoding'].to_s.strip.downcase
      when '', 'identity' then body.force_encoding('UTF-8')
      when 'gzip' then Zlib::GzipReader.new(StringIO.new(body)).read.force_encoding('UTF-8')
      else raise Stop.new('unsupported-content-encoding')
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
      limit = @read_only ? READ_ONLY_RPC_ORDER.length : RPC_ORDER.length
      raise Stop.new('too-many-rpcs') if @rpc_count >= limit
    end

    def validate_pairs!(pairs)
      keys = pairs.map(&:first)
      raise Stop.new('duplicate-param') unless keys.uniq.length == keys.length
      raise Stop.new('unexpected-param') unless (keys - SAFE_FIELDS).empty?
      raise Stop.new('forbidden-request') unless (keys & FORBIDDEN_RPC_KEYS).empty?
    end

    def classify_rpc(params)
      matches = RPC_ORDER.uniq.select { |key| params.key?(key) }
      raise Stop.new('unknown-rpc') unless matches.length == 1
      matches.first
    end

    def validate_params!(rpc, params, ordinal)
      raise Stop.new('bad-version') unless params['app_version'] == VERSION
      case rpc
      when 'auth_id_password'
        raise Stop.new('bad-auth-account') unless params['id_player'] == @account_id
        raise Stop.new('auth-has-session') if params.key?('session_id')
      when 'player_get_info'
        require_bound_session!(params)
        raise Stop.new('bad-info-account') unless params['id'] == @account_id
      when 'chat_display'
        require_bound_session!(params)
        raise Stop.new('bad-room') unless params['room'] == ROOM
        expected = ordinal == 3 ? '' : @prior_room_last_message.to_s
        raise Stop.new('bad-read-cursor') unless params['last_message'].to_s == expected
      when 'chat_send'
        require_bound_session!(params)
        raise Stop.new('send-before-name-check') unless @name_checked
        raise Stop.new('bad-send-account') unless params['id_player'] == @account_id
        raise Stop.new('bad-room') unless params['room'] == ROOM
        raise Stop.new('bad-message') unless params['message'] == @expected_message
        actual_prior = room_last_message
        if actual_prior && !actual_prior.empty?
          raise Stop.new('querycursor-roomstate-mismatch') unless params['last_message'].to_s == actual_prior
          @prior_room_last_message = actual_prior
          @checks << 'querycursor_matches_actual_saved_prior_roomstate'
        end
        raise Stop.new('bad-send-cursor') unless params['last_message'].to_s == @prior_room_last_message.to_s
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

    def open_room_locally!
      return unless Object.const_defined?(:GAME)
      game = Object.const_get(:GAME)
      return unless game.respond_to?(:chat) && game.chat
      game.chat.open(ROOM.to_i)
      @checks << 'room_opened_locally'
    end

    def room_last_message
      return '' unless Object.const_defined?(:GAME)
      room = Object.const_get(:GAME).chat.detect { |r| r.id == ROOM.to_i }
      room&.last_message.to_s
    end

    def last_timestamp_from_chat_body(body)
      chat_records(body).map { |record| record.split(',', -1).first.to_s }.last.to_s
    end

    def validate_chat_body_or_stop!(body, label)
      classify_chat_body(body, label).tap do |shape|
        raise Stop.new('unsupported-malformed-first-read') if shape['type'] == 'malformed'
      end
    end

    def classify_chat_body(body, label)
      raw = body.to_s
      shape = { 'label' => label, 'bytecount' => raw.bytesize, 'empty' => raw.empty? }
      if raw.empty?
        shape.merge('type' => 'empty')
      elsif raw == '7' || raw.start_with?('7,', '7;')
        shape.merge('type' => 'protocol_error', 'recordcounts' => record_counts(raw), 'fieldcounts' => field_counts(raw))
      else
        records = chat_records(raw)
        counts = records.map { |record| record.split(',', -1).length }
        chatshaped = !records.empty? && counts.all? { |count| count == 7 }
        shape.merge('type' => chatshaped ? 'chat' : 'malformed', 'recordcounts' => records.length, 'fieldcounts' => counts, 'chatshaped' => chatshaped)
      end
    end

    def chat_records(body)
      raw = body.to_s
      return [] if raw.empty? || raw == '7' || raw.start_with?('7,', '7;')
      raw.split(';').flat_map { |section| section.split('|') }.reject(&:empty?)
    end

    def update_publication_from_chat_body!(body)
      return if @read_only || !@send_attempted
      seen = safe_own_match?(body)
      @own_message_seen_by_response ||= seen
      @chat_publication_status_by_response = @own_message_seen_by_response ? 'confirmed' : 'unconfirmed'
    end

    def safe_own_match?(body)
      chat_records(body).any? do |record|
        fields = record.split(',', -1)
        fields.length == 7 && fields[2].to_s == @expected_message && fields[3].to_s == @account_id
      end
    end

    def capture_response(response, body, rpc)
      key = response_capture_key(rpc)
      return unless key && @private_paths[key]
      raw_path = @private_paths.fetch(key)
      headers_path = @private_paths.fetch("#{key}_headers".to_sym)
      truncated = false
      File.open(raw_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        if body.bytesize > BODY_CAPTURE_LIMIT
          file.write(body.byteslice(0, BODY_CAPTURE_LIMIT)); truncated = true
        else
          file.write(body)
        end
      end
      headers = {}
      response.each_header { |k, v| headers[k] = v.to_s } if response.respond_to?(:each_header)
      File.open(headers_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.pretty_generate('status' => response.code.to_i, 'headers' => headers)) }
      safe = safe_response_summary(rpc, response, body)
      record_response_summary(rpc, safe)
      @ledger.update!('responses' => @responses, 'statuses' => @statuses, 'rpc_count' => @rpc_count)
    end

    def record_response_summary(rpc, safe)
      if rpc == 'chat_display' && !@read_only
        existing = @responses[rpc]
        @responses[rpc] = existing ? Array(existing) + [safe] : [safe]
      else
        @responses[rpc] = safe
      end
    end

    def response_capture_key(rpc)
      return :auth_raw if rpc == 'auth_id_password'
      return :profile_raw if rpc == 'player_get_info'
      return :read_raw if rpc == 'chat_display' && @read_only
      return @rpc_count == 3 ? :read_before_raw : :read_after_raw if rpc == 'chat_display'

      nil
    end

    def safe_response_summary(rpc, response, body)
      base = { 'bytecount' => body.to_s.bytesize, 'empty' => body.to_s.empty?, 'http_status' => response.code.to_i }
      case rpc
      when 'auth_id_password'
        sections = body.to_s.split(';')
        base.merge('type' => 'auth', 'sectioncount' => sections.length, 'fieldcounts' => sections.map { |section| section.split(',', -1).length })
      when 'player_get_info'
        sections = body.to_s.split(';')
        base.merge('type' => 'profile', 'sectioncount' => sections.length, 'fieldcounts' => sections.map { |section| section.split(',', -1).length })
      when 'chat_display'
        update_publication_from_chat_body!(body)
        classify_chat_body(body, 'read-response').merge(
          'http_status' => response.code.to_i,
          'read_phase' => @rpc_count == 3 ? 'before_send' : 'after_send',
          'safe_own_match' => safe_own_match?(body)
        )
      else
        base.merge('type' => 'unknown')
      end
    rescue StandardError => e
      base.merge('type' => 'safe_exception', 'safeexceptiontypeenum' => safe_transport_exception_class(e))
    end

    def capture_send_response(response, body)
      File.open(@private_paths.fetch(:raw), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        if body.bytesize > BODY_CAPTURE_LIMIT
          file.write(body.byteslice(0, BODY_CAPTURE_LIMIT))
          truncated = true
        else
          file.write(body)
          truncated = false
        end
        @send_truncated = truncated
      end
      headers = {}
      response.each_header { |k, v| headers[k] = v.to_s } if response.respond_to?(:each_header)
      File.open(@private_paths.fetch(:headers), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate('status' => response.code.to_i, 'headers' => headers))
      end
      safe = classify_chat_body(body, 'send-response').merge('http_status' => response.code.to_i, 'private_raw_capture' => File.basename(@private_paths.fetch(:raw)), 'private_headers_capture' => File.basename(@private_paths.fetch(:headers)), 'truncated_private_raw' => @send_truncated == true)
      @ledger.update!('send_response' => safe, 'statuses' => @statuses, 'rpc_count' => @rpc_count)
    end

    def record_counts(raw) = raw.split(';').length
    def field_counts(raw) = raw.split(';').map { |r| r.split(',', -1).length }
  end

  def self.run(argv) = new.run(argv)
  def run(argv)
    attempt = parse_attempt(argv)
    return invalid_attempt unless attempt
    read_only = argv.include?('--read-only')
    return invalid_read_only_attempt if read_only && attempt != '3'
    return invalid_attempt if attempt == '3' && argv.include?('--live') && !read_only
    argv.include?('--live') ? live(attempt, read_only: read_only) : self_test
  end

  def parse_attempt(argv)
    raw = argv.find { |arg| arg.start_with?('--attempt=') }
    attempt = raw ? raw.split('=', 2).last.to_s : '1'
    ATTEMPTS.include?(attempt) ? attempt : nil
  end

  def invalid_attempt
    puts(JSON.generate(safe_public(SAFE_INITIAL.merge('classification' => 'invalid-attempt', 'stop' => 'invalid-attempt', 'exit' => 1))))
    1
  end
  def invalid_read_only_attempt
    puts(JSON.generate(safe_public(SAFE_INITIAL.merge('classification' => 'read-only-attempt-refused', 'stop' => 'read-only-attempt-refused', 'exit' => 1))))
    1
  end

  def self.diagnostic_paths(attempt, account_dir = ACCOUNT_DIR)
    suffix = attempt.to_s == '1' ? '' : "-attempt-#{attempt}"
    {
      ledger: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.json"),
      stdout: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.stdout"),
      stderr: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.stderr"),
      raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.send-response.raw"),
      headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.send-response.headers.json"),
      auth_raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.auth-response.raw"),
      auth_headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.auth-response.headers.json"),
      profile_raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.profile-response.raw"),
      profile_headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.profile-response.headers.json"),
      read_raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-response.raw"),
      read_headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-response.headers.json"),
      read_before_raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-before-response.raw"),
      read_before_headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-before-response.headers.json"),
      read_after_raw: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-after-response.raw"),
      read_after_headers: File.join(account_dir, "cli-chat-diagnostic-world999#{suffix}.read-after-response.headers.json")
    }
  end

  def diagnostic_paths(attempt, account_dir = ACCOUNT_DIR) = self.class.diagnostic_paths(attempt, account_dir)
  def message_for_attempt(attempt)
    case attempt.to_s
    when '4' then ATTEMPT4_MESSAGE
    when '5', '6' then ATTEMPT5_MESSAGE
    else MESSAGE
    end
  end

  def live(attempt = '1', read_only: false)
    ledger = nil; guard = nil; ledger_created = false; exit_code = 1
    summary = SAFE_INITIAL.merge('classification' => 'unknown')
    out0 = err0 = outcap = errcap = nil
    begin
      paths = diagnostic_paths(attempt)
      ensure_account_dir!
      account_id = read_account_id!
      ledger = Ledger.new(paths.fetch(:ledger))
      ledger.create_exclusive!
      ledger_created = true
      capture_paths = read_only ? [:auth_raw, :auth_headers, :profile_raw, :profile_headers, :read_raw, :read_headers] : [:raw, :headers, :read_before_raw, :read_before_headers, :read_after_raw, :read_after_headers]
      ([paths.fetch(:stdout), paths.fetch(:stderr)] + capture_paths.map { |k| paths.fetch(k) }).each { |p| secure_private_file(p) }
      private_paths = if read_only
                        { auth_raw: paths.fetch(:auth_raw), auth_raw_headers: paths.fetch(:auth_headers), profile_raw: paths.fetch(:profile_raw), profile_raw_headers: paths.fetch(:profile_headers), read_raw: paths.fetch(:read_raw), read_raw_headers: paths.fetch(:read_headers) }
                      else
                        { raw: paths.fetch(:raw), headers: paths.fetch(:headers), read_before_raw: paths.fetch(:read_before_raw), read_before_raw_headers: paths.fetch(:read_before_headers), read_after_raw: paths.fetch(:read_after_raw), read_after_raw_headers: paths.fetch(:read_after_headers) }
                      end
      expected_message = message_for_attempt(attempt)
      guard = HttpGuard.new(ledger: ledger, account_id: account_id, private_paths: private_paths, read_only: read_only, expected_message: expected_message)
      summary.merge!('attempt' => attempt, 'read_only' => read_only, 'ledger' => File.basename(paths.fetch(:ledger)), 'stdout_capture' => File.basename(paths.fetch(:stdout)), 'stderr_capture' => File.basename(paths.fetch(:stderr)))
      guard.install!
      out0 = $stdout; err0 = $stderr
      File.open(paths.fetch(:stdout), File::WRONLY | File::TRUNC, 0o600) do |out|
        File.open(paths.fetch(:stderr), File::WRONLY | File::TRUNC, 0o600) do |err|
          outcap = out; errcap = err; $stdout = out; $stderr = err
          begin
            CLI_RESULTS.clear if defined?(CLI_RESULTS) && CLI_RESULTS.respond_to?(:clear)
            reset_cli_batch_state!
            commands = read_only ? READ_ONLY_COMMANDS : commands_for_attempt(attempt)
            ARGV.replace(['-m', '-c', CONFIG_PATH, *commands.flat_map { |cmd| ['-e', cmd] }, '--json'])
            load SANDBOX_PATH
            exit_code = 0
          rescue SystemExit => e
            exit_code = e.status || 0
          rescue Stop => e
            summary['stop'] = e.classification; summary['classification'] = e.classification; exit_code = 1
          rescue StandardError => e
            failure = ledger&.data&.fetch('transport_failure', nil)
            if failure
              summary['stop'] = 'transport-failure'; summary['classification'] = 'transport-failure'; summary['transport_failure'] = failure
            else
              summary['stop'] = 'transporterror'; summary['classification'] = 'exception-before-complete'; summary['transport_failure'] = { 'operation' => 'unknown', 'ordinal' => guard&.rpc_count.to_i, 'exception_class' => 'transporterror', 'transport_error' => 'transporterror' }
            end
            exit_code = 1
          ensure
            cleanup_room
            $stdout = out0; $stderr = err0
          end
        end
      end
    rescue Stop => e
      summary['classification'] = e.classification; summary['stop'] = e.classification; exit_code = 1
    ensure
      cleanup_room
      guard&.uninstall!
      $stdout = out0 if out0 && $stdout.equal?(outcap)
      $stderr = err0 if err0 && $stderr.equal?(errcap)
    end
    if ledger_created
      cli = parse_cli_summary(paths.fetch(:stdout))
      responses = ledger.data['responses'] || guard&.responses || {}
      cli_count = cli_chat_count(cli)
      parsed_count = parsed_chat_count(responses.fetch('chat_display', nil))
      count_provenance = parsed_count.nil? ? 'cli_summary' : 'parsed_read_response'
      own_seen = read_only ? false : (guard&.own_message_seen_by_response == true)
      publication_status = read_only ? nil : (guard&.chat_publication_status_by_response || 'unconfirmed')
      final = summary.merge('exit' => exit_code, 'rpc_count' => guard&.rpc_count.to_i, 'statuses' => guard&.statuses || [], 'checks' => guard&.checks || [], 'send_attempted' => guard&.send_attempted == true, 'own_message_seen' => own_seen, 'chat_publication_status' => publication_status, 'chat_message_count' => parsed_count || cli_count, 'chat_count_provenance' => count_provenance, 'cli_summary_chat_count' => cli_count, 'send_response' => ledger.data['send_response'], 'responses' => responses, 'transport_failure' => summary['transport_failure'] || ledger.data['transport_failure'])
      final['classification'] = classify_final(final, cli, read_only: read_only)
      final['exit'] = 0 if final['classification'] == 'read-only-completed'
      final['stop'] ||= final['classification'] unless %w[completed-confirmed read-only-completed].include?(final['classification'])
      ledger.update!(final)
      puts(JSON.generate(safe_public(final)))
      return %w[completed-confirmed read-only-completed].include?(final['classification']) ? 0 : 1
    end
    puts(JSON.generate(safe_public(summary.merge('exit' => exit_code))))
    1
  end

  def reset_cli_batch_state!
    Object.constants.grep(/\A(?:CLI_RESULTS|CHAT_ROOMS|CONTEXT_|LIB_DIR|BASE_DIR|DATA_DIR|CONFIGS_DIR|DEFAULT_CONFIG|CONFIG_EXT|COUNTRIES_FILE|BANNER|MINIMAL_CONNECT|GAME|SHELL|LOGGER)/).each { |n| Object.send(:remove_const, n) if Object.const_defined?(n, false) }
    $LOADED_FEATURES.reject! { |f| f.match?(%r{/lib/cli(?:\.rb|/)}) }
  end
  def cleanup_room
    Object.const_get(:GAME).chat.close(ROOM.to_i) if Object.const_defined?(:GAME) && Object.const_get(:GAME).respond_to?(:chat)
  rescue StandardError
    nil
  end
  def ensure_account_dir!
    stat = File.stat(ACCOUNT_DIR)
    raise Stop.new('account-dir-not-private') unless stat.directory? && (stat.mode & 0o777) == 0o700
    raise Stop.new('missing-config') unless File.file?(CONFIG_PATH)
  end
  def read_account_id!
    id = JSON.parse(File.read(CONFIG_PATH)).fetch('id').to_s
    raise Stop.new('missing-account-id') if id.empty?
    id
  rescue JSON::ParserError, KeyError
    raise Stop.new('invalid-config')
  end
  def secure_private_file(path) = File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |_f| }
  def parse_cli_summary(path)
    return {} unless path && File.file?(path)
    File.readlines(path, chomp: true).reverse_each do |line|
      s = line.strip
      next unless s.start_with?('{') && s.end_with?('}')
      parsed = JSON.parse(s)
      return parsed if parsed.is_a?(Hash) && parsed.key?('own_message_seen')
    rescue JSON::ParserError
      next
    end
    {}
  end
  def cli_chat_count(cli)
    cli.fetch('chat_message_count', cli.fetch('chat_last_read_count', 0)).to_i
  end
  def parsed_chat_count(read_response)
    read_response = read_response.reverse.find { |item| item.is_a?(Hash) && item['read_phase'] == 'after_send' } || read_response.last if read_response.is_a?(Array)
    return nil unless read_response.is_a?(Hash)
    return 0 if read_response['type'] == 'empty'
    return read_response['recordcounts'].to_i if read_response['type'] == 'chat' && read_response.key?('recordcounts')
    nil
  end
  def classify_final(final, cli, read_only: false)
    return 'transport-failure' if final['transport_failure']
    return final['classification'] if final['classification'] && final['classification'] != 'unknown'
    return 'read-only-completed' if read_only && final['rpc_count'] == 3 && final['send_attempted'] == false
    return 'completed-confirmed' if final['exit'] == 0 && final['send_attempted'] && final['own_message_seen'] == true && final['chat_publication_status'] == 'confirmed' && cli['chat_publication_status'] == 'confirmed'
    return 'send-attempted-unconfirmed' if final['send_attempted']
    'stopped-before-send'
  end
  def safe_public(final)
    final.slice('classification', 'send_attempted', 'own_message_seen', 'chat_publication_status', 'chat_message_count', 'chat_count_provenance', 'cli_summary_chat_count', 'rpc_count', 'statuses', 'checks', 'send_response', 'responses', 'transport_failure', 'exit', 'stop')
  end

  def self_test
    tests = [test_failed_profile_capture_safe_reason, test_attempt_suffix_isolated, test_attempt_no_overwrite, test_original_attempt_paths, test_invalid_attempt_no_io, test_read_only_attempts_refused_no_io, test_attempt4_message_and_paths, test_attempt5_message_and_read_captures, test_classifier_multirecord_counts, test_read_only_count_from_private_read, test_offline_success, test_real_cli_name_mismatch, test_exact_five_success, test_malformed_before_parser, test_persistent_cursor, test_repeated_display_ordinal, test_uncertain_send, test_existing_ledger_refusal, test_secret_redaction, test_transport_and_sixth_rpc, test_read_only_success_no_send, test_read_only_empty_chat_success, test_read_only_send_forbidden, test_read_only_private_capture_before_parse]
    failed = tests.reject { |r| r[:ok] }
    puts(JSON.generate(mode: 'self-test', ok: failed.empty?, tests: tests))
    failed.empty? ? 0 : 1
  end

  def test_failed_profile_capture_safe_reason
    result = offline_real_cli(profile_name: EXPECTED_NAME, raise_rpc: 'player_get_info')
    failure = result[:public]['transport_failure'] || {}
    ok = result[:exit] == 1 && result[:public]['classification'] == 'transport-failure' && result[:public]['send_attempted'] == false && result[:public]['statuses'] == [200] && failure['operation'] == 'player_get_info' && failure['ordinal'] == 2 && failure['exception_class'] == 'Net::ReadTimeout' && !JSON.generate(result[:public]).include?('execution expired')
    pass('failedprofilecapturessafereason') { ok }
  end
  def test_attempt_suffix_isolated
    Dir.mktmpdir do |dir|
      one = diagnostic_paths('1', dir); two = diagnostic_paths('2', dir); three = diagnostic_paths('3', dir); four = diagnostic_paths('4', dir); five = diagnostic_paths('5', dir)
      ok = one.values.none? { |path| path.include?('attempt-') } && two.values.all? { |path| File.basename(path).include?('attempt-2') } && three.values.all? { |path| File.basename(path).include?('attempt-3') } && four.values.all? { |path| File.basename(path).include?('attempt-4') } && five.values.all? { |path| File.basename(path).include?('attempt-5') } && (one.values & two.values).empty? && (two.values & three.values).empty? && (three.values & four.values).empty? && (four.values & five.values).empty?
      pass('suffixisolated') { ok }
    end
  end
  def test_attempt_no_overwrite
    result = offline_real_cli(profile_name: EXPECTED_NAME, attempt: '2', preexisting_ledger: true)
    pass('nooverwrite') { result[:exit] == 1 && result[:public]['classification'] == 'existing-ledger-refused' && result[:calls].empty? && result[:ledger_contents] == 'prior-ledger' }
  end
  def test_original_attempt_paths
    Dir.mktmpdir do |dir|
      paths = diagnostic_paths('1', dir)
      pass('originalpaths') { paths[:ledger] == File.join(dir, 'cli-chat-diagnostic-world999.json') && paths[:stdout] == File.join(dir, 'cli-chat-diagnostic-world999.stdout') && paths[:stderr] == File.join(dir, 'cli-chat-diagnostic-world999.stderr') && paths[:raw] == File.join(dir, 'cli-chat-diagnostic-world999.send-response.raw') && paths[:headers] == File.join(dir, 'cli-chat-diagnostic-world999.send-response.headers.json') }
    end
  end
  def test_invalid_attempt_no_io
    checker = CliChatDiagnosticCheck.new
    def checker.ensure_account_dir! = raise('private IO attempted')
    output = capture_stdout { @invalid_attempt_exit = checker.run(['--live', '--attempt=7']) }
    public = JSON.parse(output.lines.last.to_s)
    pass('invalidattemptnoIO') { @invalid_attempt_exit == 1 && public['classification'] == 'invalid-attempt' }
  end
  def test_read_only_attempts_refused_no_io
    checker = CliChatDiagnosticCheck.new
    def checker.ensure_account_dir! = raise('private IO attempted')
    out1 = capture_stdout { @readonly_attempt1_exit = checker.run(['--live', '--read-only', '--attempt=1']) }
    out2 = capture_stdout { @readonly_attempt2_exit = checker.run(['--live', '--read-only', '--attempt=2']) }
    out3 = capture_stdout { @attempt3_without_readonly_exit = checker.run(['--live', '--attempt=3']) }
    out4 = capture_stdout { @readonly_attempt4_exit = checker.run(['--live', '--read-only', '--attempt=4']) }
    out5 = capture_stdout { @readonly_attempt5_exit = checker.run(['--live', '--read-only', '--attempt=5']) }
    p1 = JSON.parse(out1.lines.last.to_s); p2 = JSON.parse(out2.lines.last.to_s); p3 = JSON.parse(out3.lines.last.to_s); p4 = JSON.parse(out4.lines.last.to_s); p5 = JSON.parse(out5.lines.last.to_s)
    pass('readonlyattempt1/2/4/5refusedbeforeIO') { @readonly_attempt1_exit == 1 && @readonly_attempt2_exit == 1 && @attempt3_without_readonly_exit == 1 && @readonly_attempt4_exit == 1 && @readonly_attempt5_exit == 1 && p1['classification'] == 'read-only-attempt-refused' && p2['classification'] == 'read-only-attempt-refused' && p3['classification'] == 'invalid-attempt' && p4['classification'] == 'read-only-attempt-refused' && p5['classification'] == 'read-only-attempt-refused' }
  end

  def test_attempt5_message_and_read_captures
    result = offline_real_cli(profile_name: EXPECTED_NAME, attempt: '5')
    chat_responses = result[:public].fetch('responses', {}).fetch('chat_display', [])
    ok = result[:exit] == 0 && result[:public]['rpc_count'] == 5 && result[:sent_messages] == ['Test codificacion'] && result[:ledger_basename] == 'cli-chat-diagnostic-world999-attempt-5.json' && result[:raw_bodies][:read_before_raw].to_s.include?('2024-01-01T00:00:01Z') && result[:raw_bodies][:read_after_raw].to_s.include?('Test codificacion') && chat_responses.is_a?(Array) && chat_responses.map { |r| r['read_phase'] } == %w[before_send after_send] && chat_responses.map { |r| r['safe_own_match'] } == [false, true] && result[:public]['chat_message_count'] == 1 && result[:public]['chat_count_provenance'] == 'parsed_read_response'
    pass('attempt5messagebothreadcapturescounts') { ok }
  end

  def test_attempt4_message_and_paths
    result = offline_real_cli(profile_name: EXPECTED_NAME, attempt: '4')
    ok = result[:exit] == 0 && result[:public]['rpc_count'] == 5 && result[:calls] == %w[auth_id_password player_get_info chat_display chat_send chat_display] && result[:sent_messages] == ['Test protocolo'] && result[:ledger_basename] == 'cli-chat-diagnostic-world999-attempt-4.json'
    pass('attempt4messagepaths') { ok }
  end

  def test_classifier_multirecord_counts
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_private_paths(File.dirname(ledger.path)))
      shape = guard.send(:classify_chat_body, "t1,n,m,42,1,1,999;t2,n,m,42,1,1,999", 'multi')
      pass('classifiermultirecordcounts') { shape['type'] == 'chat' && shape['recordcounts'] == 2 && shape['fieldcounts'] == [7, 7] }
    end
  end

  def test_read_only_count_from_private_read
    body = "t1,n,m,42,1,1,999;t2,n,m,7,1,1,999"
    result = offline_real_cli(profile_name: EXPECTED_NAME, attempt: '3', read_only: true, first_read_body: body)
    pass('readonlycountfromprivateparsedread') { result[:exit] == 0 && result[:public]['chat_message_count'] == 2 && result[:public]['chat_count_provenance'] == 'parsed_read_response' && result[:public]['cli_summary_chat_count'] == 0 }
  end

  def test_offline_success
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_private_paths(File.dirname(ledger.path)))
      http = fake_http
      successful_requests.each { |request, body| guard.before_request(http, request); guard.after_response(fake_response(200, body)) }
      pass('offline exact five success') { guard.rpc_count == 5 && guard.statuses == [200, 200, 200, 200, 200] && guard.send_attempted }
    end
  end
  def test_real_cli_name_mismatch
    result = offline_real_cli(profile_name: 'Mismatch')
    pass('selftest realCLI name mismatch') { result[:exit] == 1 && result[:public]['classification'] == 'name-mismatch' && result[:calls] == %w[auth_id_password player_get_info] }
  end
  def test_exact_five_success
    result = offline_real_cli(profile_name: EXPECTED_NAME)
    pass('exact5success') { result[:exit] == 0 && result[:public]['rpc_count'] == 5 && result[:calls] == %w[auth_id_password player_get_info chat_display chat_send chat_display] }
  end
  def test_malformed_before_parser
    result = offline_real_cli(profile_name: EXPECTED_NAME, first_read_body: 'bad,body')
    ok = %w[unsupported-malformed-first-read stopped-before-send].include?(result[:public]['classification']) && result[:public]['send_attempted'] == false && result[:calls] == %w[auth_id_password player_get_info chat_display]
    pass('rejection/malformedbodycaptured BEFORE parser') { ok }
  end
  def test_persistent_cursor
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_private_paths(File.dirname(ledger.path)))
      http = fake_http
      advance_auth_info(guard, http)
      guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION)); guard.after_response(fake_response(200, chat_response(time: '2024-01-01T00:00:01Z')))
      guard.before_request(http, query('chat_send' => '', 'room' => ROOM, 'last_message' => '2024-01-01T00:00:01Z', 'message' => MESSAGE, 'id_player' => '42', 'session_id' => 'sid', 'app_version' => VERSION))
      pass('persistentcursor sendnonempty fixture matching readtimestamp') { true }
    end
  rescue Stop => e
    pass('persistentcursor sendnonempty fixture matching readtimestamp') { false && e }
  end
  def test_repeated_display_ordinal
    assert_stop('repeateddisplay ordinal', 'unexpected-rpc-order') { |guard, http| advance_auth_info(guard, http); guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION)); guard.after_response(fake_response(200, chat_response(time: '2024-01-01T00:00:01Z'))); guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => '2024-01-01T00:00:01Z', 'session_id' => 'sid', 'app_version' => VERSION)) }
  end
  def test_uncertain_send
    result = offline_real_cli(profile_name: EXPECTED_NAME, send_body: chat_response(time: '2024-01-01T00:00:02Z', own: false), final_own: false)
    pass('uncertain send') { result[:exit] == 1 && result[:public]['classification'] == 'send-attempted-unconfirmed' && result[:public]['send_attempted'] == true }
  end
  def test_existing_ledger_refusal
    Dir.mktmpdir { |dir| path = File.join(dir, 'ledger.json'); File.write(path, '{}'); begin Ledger.new(path).create_exclusive!; pass('ledgerexists refusal') { false }; rescue Stop => e; pass('ledgerexists refusal') { e.classification == 'existing-ledger-refused' }; end }
  end
  def test_secret_redaction
    result = offline_real_cli(profile_name: EXPECTED_NAME, send_body: 'SECRET_MARKER,hidden,values,42,1,1,999')
    ok = !JSON.generate(result[:public]).include?('SECRET_MARKER')
    pass('secretmarkerpublicredaction') { ok }
  end
  def test_transport_and_sixth_rpc
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_private_paths(File.dirname(ledger.path)))
      http = fake_http
      successful_requests.each { |request, body| guard.before_request(http, request); guard.after_response(fake_response(200, body)) }
      begin
        guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => 't2', 'session_id' => 'sid', 'app_version' => VERSION))
      rescue Stop => e
        return pass('TLS/proxy/destination/no sixthRPC') { e.classification == 'too-many-rpcs' }
      end
      pass('TLS/proxy/destination/no sixthRPC') { false }
    end
  end
  def test_read_only_success_no_send
    result = offline_real_cli(profile_name: EXPECTED_NAME, attempt: '3', read_only: true)
    public_json = JSON.generate(result[:public])
    response_keys = result[:public].fetch('responses', {}).keys.sort
    modes = result[:capture_modes].values.compact
    ok = result[:exit] == 0 && result[:public]['classification'] == 'read-only-completed' && result[:public]['send_attempted'] == false && result[:public]['own_message_seen'] == false && result[:public]['rpc_count'] == 3 && result[:calls] == %w[auth_id_password player_get_info chat_display] && response_keys == %w[auth_id_password chat_display player_get_info] && modes.all? { |mode| mode == '600' } && !public_json.include?('sid') && !public_json.include?(EXPECTED_NAME) && !public_json.include?(MESSAGE)
    pass('readonly3successnosendprivatecapturesafe') { ok }
  end
  def test_read_only_empty_chat_success
    with_temp_ledger do |ledger|
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_read_only_private_paths(File.dirname(ledger.path)), read_only: true)
      http = fake_http
      advance_auth_info(guard, http)
      guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION)); guard.after_response(fake_response(200, ''))
      chat = guard.responses.fetch('chat_display', {})
      final = { 'transport_failure' => nil, 'classification' => 'unknown', 'rpc_count' => guard.rpc_count, 'send_attempted' => guard.send_attempted, 'exit' => 0 }
      pass('readonlyemptychatvalid') { classify_final(final, {}, read_only: true) == 'read-only-completed' && guard.send_attempted == false && chat['empty'] == true && chat['type'] == 'empty' }
    end
  end
  def test_read_only_send_forbidden
    assert_stop('readonlyforbidssend', 'read-only-send-forbidden') do |guard, http|
      ro_guard = HttpGuard.new(ledger: guard.instance_variable_get(:@ledger), account_id: '42', private_paths: temp_private_paths(File.dirname(guard.instance_variable_get(:@ledger).path)), read_only: true)
      advance_auth_info(ro_guard, http)
      ro_guard.before_request(http, query('chat_send' => '', 'room' => ROOM, 'last_message' => '', 'message' => MESSAGE, 'id_player' => '42', 'session_id' => 'sid', 'app_version' => VERSION))
    end
  end
  def test_read_only_private_capture_before_parse
    with_temp_ledger do |ledger|
      paths = temp_read_only_private_paths(File.dirname(ledger.path))
      guard = HttpGuard.new(ledger: ledger, account_id: '42', private_paths: paths, read_only: true)
      http = fake_http
      begin
        advance_auth_info(guard, http)
        guard.before_request(http, query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION)); guard.after_response(fake_response(200, 'SECRET_MARKER,bad'))
      rescue Stop => e
        public = safe_public(JSON.parse(File.read(ledger.path)).merge('classification' => e.classification, 'stop' => e.classification, 'send_attempted' => guard.send_attempted, 'rpc_count' => guard.rpc_count, 'statuses' => guard.statuses))
        ok = e.classification == 'unsupported-malformed-first-read' && File.read(paths.fetch(:read_raw)) == 'SECRET_MARKER,bad' && !JSON.generate(public).include?('SECRET_MARKER')
        return pass('rawprivatecapturebeforeparseandsafepublic') { ok }
      end
      pass('rawprivatecapturebeforeparseandsafepublic') { false }
    end
  end

  def assert_stop(name, classification)
    with_temp_ledger { |ledger| yield HttpGuard.new(ledger: ledger, account_id: '42', private_paths: temp_private_paths(File.dirname(ledger.path))), fake_http; pass(name) { false } }
  rescue Stop => e
    pass(name) { e.classification == classification }
  end
  def advance_auth_info(guard, http)
    guard.before_request(http, query('auth_id_password' => nil, 'id_player' => '42', 'password' => 'secret', 'app_version' => VERSION)); guard.after_response(fake_response(200, auth_response('sid')))
    guard.before_request(http, query('player_get_info' => '', 'id' => '42', 'session_id' => 'sid', 'app_version' => VERSION)); guard.after_response(fake_response(200, profile_response(EXPECTED_NAME)))
  end
  def successful_requests
    [[query('auth_id_password' => nil, 'id_player' => '42', 'password' => 'secret', 'app_version' => VERSION), auth_response('sid')], [query('player_get_info' => '', 'id' => '42', 'session_id' => 'sid', 'app_version' => VERSION), profile_response(EXPECTED_NAME)], [query('chat_display' => '', 'room' => ROOM, 'last_message' => '', 'session_id' => 'sid', 'app_version' => VERSION), chat_response(time: '2024-01-01T00:00:01Z')], [query('chat_send' => '', 'room' => ROOM, 'last_message' => '2024-01-01T00:00:01Z', 'message' => MESSAGE, 'id_player' => '42', 'session_id' => 'sid', 'app_version' => VERSION), chat_response(time: '2024-01-01T00:00:02Z')], [query('chat_display' => '', 'room' => ROOM, 'last_message' => '2024-01-01T00:00:02Z', 'session_id' => 'sid', 'app_version' => VERSION), chat_response(time: '2024-01-01T00:00:03Z')]]
  end
  def offline_real_cli(profile_name:, first_read_body: nil, send_body: nil, final_own: true, raise_rpc: nil, attempt: '1', preexisting_ledger: false, read_only: false)
    Dir.mktmpdir do |dir|
      account_dir = File.join(dir, 'account'); Dir.mkdir(account_dir, 0o700)
      config = File.join(account_dir, 'credentials.json'); File.write(config, JSON.generate('id' => '42', 'password' => 'secret'))
      calls = []
      sent_messages = []
      paths = diagnostic_paths(attempt, account_dir)
      File.write(paths.fetch(:ledger), 'prior-ledger') if preexisting_ledger
      install_offline_http_stub(calls, sent_messages, profile_name, first_read_body, send_body, final_own, raise_rpc)
      begin
        with_constants('ACCOUNT_DIR' => account_dir, 'CONFIG_PATH' => config, 'LEDGER_PATH' => File.join(account_dir, 'ledger.json'), 'STDOUT_PATH' => File.join(account_dir, 'stdout.log'), 'STDERR_PATH' => File.join(account_dir, 'stderr.log'), 'SEND_RAW_PATH' => File.join(account_dir, 'send.raw'), 'SEND_HEADERS_PATH' => File.join(account_dir, 'send.headers.json')) do
          output = capture_stdout { @offline_exit = live(attempt, read_only: read_only) }
          capture_keys = [:auth_raw, :auth_headers, :profile_raw, :profile_headers, :read_raw, :read_headers, :read_before_raw, :read_before_headers, :read_after_raw, :read_after_headers]
          modes = capture_keys.each_with_object({}) { |key, out| out[key] = File.file?(paths.fetch(key)) ? format('%o', File.stat(paths.fetch(key)).mode & 0o777) : nil }
          raw_bodies = [:auth_raw, :profile_raw, :read_raw, :read_before_raw, :read_after_raw].each_with_object({}) { |key, out| out[key] = File.file?(paths.fetch(key)) ? File.read(paths.fetch(key)) : nil }
          { exit: @offline_exit, public: JSON.parse(output.lines.last.to_s), calls: calls, sent_messages: sent_messages, ledger_basename: File.basename(paths.fetch(:ledger)), ledger_contents: File.file?(paths.fetch(:ledger)) ? File.read(paths.fetch(:ledger)) : nil, capture_modes: modes, raw_bodies: raw_bodies }
        end
      ensure
        uninstall_offline_http_stub
      end
    end
  end
  def install_offline_http_stub(calls, sent_messages, profile_name, first_read_body, send_body, final_own, raise_rpc = nil)
    @orig_req = Net::HTTP.instance_method(:request); @orig_start = Net::HTTP.instance_method(:start); @orig_started = Net::HTTP.instance_method(:started?)
    Net::HTTP.send(:define_method, :started?) { false }
    Net::HTTP.send(:define_method, :start) { |&block| block ? block.call(self) : self }
    Net::HTTP.send(:define_method, :request) do |request, *_args, &block|
      params = URI.decode_www_form(URI(request.path).query.to_s).to_h
      rpc = CliChatDiagnosticCheck::HttpGuard::RPC_ORDER.uniq.detect { |k| params.key?(k) }
      calls << rpc
      raise Net::ReadTimeout, 'execution expired SECRET_MARKER' if rpc == raise_rpc
      count = calls.count(rpc)
      sent_messages << params['message'].to_s if rpc == 'chat_send'
      body = case rpc
             when 'auth_id_password' then CliChatDiagnosticCheck.new.auth_response('sid')
             when 'player_get_info' then CliChatDiagnosticCheck.new.profile_response(profile_name)
             when 'chat_display' then count == 1 ? (first_read_body || CliChatDiagnosticCheck.new.chat_response(time: '2024-01-01T00:00:01Z')) : CliChatDiagnosticCheck.new.chat_response(time: '2024-01-01T00:00:03Z', own: final_own, message: sent_messages.last || MESSAGE)
             when 'chat_send' then send_body || CliChatDiagnosticCheck.new.chat_response(time: '2024-01-01T00:00:02Z', message: sent_messages.last || MESSAGE)
             else ''
             end
      response = CliChatDiagnosticCheck.new.http_ok(body); block.call(response) if block; response
    end
  end
  def uninstall_offline_http_stub
    Net::HTTP.send(:define_method, :request, @orig_req) if @orig_req
    Net::HTTP.send(:define_method, :start, @orig_start) if @orig_start
    Net::HTTP.send(:define_method, :started?, @orig_started) if @orig_started
  end
  def with_constants(values)
    originals = {}; values.each_key { |n| originals[n] = self.class.const_get(n); self.class.send(:remove_const, n) }
    values.each { |n, v| self.class.const_set(n, v) }; yield
  ensure
    values.each_key { |n| self.class.send(:remove_const, n) if self.class.const_defined?(n, false) }
    originals.each { |n, v| self.class.const_set(n, v) }
  end
  def capture_stdout; old = $stdout; io = StringIO.new; $stdout = io; yield; io.string ensure $stdout = old end
  def with_temp_ledger; Dir.mktmpdir { |dir| ledger = Ledger.new(File.join(dir, 'ledger.json')); ledger.create_exclusive!; yield ledger } end
  def temp_private_paths(dir) = { raw: File.join(dir, 'send.raw'), headers: File.join(dir, 'send.headers.json') }
  def temp_read_only_private_paths(dir) = { auth_raw: File.join(dir, 'auth.raw'), auth_raw_headers: File.join(dir, 'auth.headers.json'), profile_raw: File.join(dir, 'profile.raw'), profile_raw_headers: File.join(dir, 'profile.headers.json'), read_raw: File.join(dir, 'read.raw'), read_raw_headers: File.join(dir, 'read.headers.json') }
  def pass(name, &block)
    { name: name, ok: block.call == true }
  rescue StandardError => e
    { name: name, ok: false, error: e.class.to_s }
  end

  FakeRequest = Struct.new(:path, :method)
  FakeResponse = Struct.new(:code, :body) do
    def [](_h) = nil
    def each_header; {}.each { |k, v| yield k, v } end
  end
  def query(params) = FakeRequest.new("#{PATH}?#{URI.encode_www_form(params)}", 'GET')
  def fake_response(code, body = '') = FakeResponse.new(code.to_s, body)
  def auth_response(sid) = ['0', '0', '0', sid, '1', '1'].join(',')
  def profile_response(name, id = '42') = [id, name, '0', '0', '0', '0', '0', '0', '0', '1', '0', '0', '0', '0', '0'].join(',')
  def chat_response(time: 't1', own: true, message: MESSAGE)
    id = own ? '42' : '7'; text = own ? message : 'Other'
    [time, EXPECTED_NAME, text, id, '1', '1', ROOM].join(',')
  end
  def http_ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK'); response.instance_variable_set(:@read, true); response.instance_variable_set(:@body, body); response
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
    def slice(*keys) = keys.each_with_object({}) { |key, out| out[key] = self[key] if key?(key) }
  end
end

exit(CliChatDiagnosticCheck.run(ARGV))
