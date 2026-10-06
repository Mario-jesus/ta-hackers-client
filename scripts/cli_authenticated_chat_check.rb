#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'stringio'
require 'zlib'
require_relative '../lib/hackers/serializer'

# One-process authorization boundary, read-only unless a bounded send prefix
# is explicitly selected. No config is read here:
# only the real CLI loads it. Import/help/default paths are entirely offline.
class CliAuthenticatedChatCheck
  EXPECTED_NAME = '[ff0000]βℓąȼЌhąţhąȼЌ'
  SANDBOX = File.expand_path('../bin/sandbox', __dir__)
  COMMANDS = ['connect', "name --expect #{EXPECTED_NAME}", 'chat read 999'].freeze
  INITIAL = { 'classification' => 'offline', 'error_class' => nil, 'rpc_count' => 0,
              'statuses' => [], 'name_verified' => false, 'message_count' => 0, 'cli_exit' => nil }.freeze

  # Not StandardError: production CLI rescue/log paths must not swallow a
  # security stop and then advance to the next command.
  class Stop < Exception
    attr_reader :classification

    def initialize(classification)
      @classification = classification
      super(classification)
    end
  end

  class Attempt
    attr_reader :out, :err

    def initialize(path)
      raise Stop, 'attempt-path-invalid' unless path.start_with?('/') && File.expand_path(path) == path

      # Never follow ancestor symlinks, inspect old contents, or reuse a name.
      ancestor = File.dirname(path)
      loop do
        stat = File.lstat(ancestor)
        raise Stop, 'attempt-path-invalid' unless stat.directory? && !stat.symlink?
        break if ancestor == '/'

        ancestor = File.dirname(ancestor)
      end
      parent = File.stat(File.dirname(path))
      raise Stop, 'attempt-parent-not-private' unless parent.uid == Process.uid && (parent.mode & 0o777) == 0o700

      Dir.mkdir(path, 0o700)
      File.chmod(0o700, path)
      @path = path
      @out = exclusive('stdout')
      @err = exclusive('stderr')
      exclusive('reservation.json') do |file|
        file.write(JSON.generate('classification' => 'read-reserved'))
        file.flush
        file.fsync
      end
      File.open(path, File::RDONLY, &:fsync)
    rescue Errno::EEXIST
      raise Stop, 'existing-attempt-refused'
    end

    # A reservation is spent even if a subsequent operation fails. Never
    # replace or delete it, and never permit transport before both syncs.
    def reserve_send(index)
      exclusive("send-#{index}.json") do |file|
        contents = JSON.generate('classification' => 'send-reserved', 'index' => index)
        raise Stop, 'reservation-failed' unless file.write(contents) == contents.bytesize

        file.flush
        file.fsync
      end
      File.open(@path, File::RDONLY, &:fsync)
    rescue StandardError
      raise Stop, 'reservation-failed'
    end

    def sync_parent!
      File.open(File.dirname(@path), File::RDONLY, &:fsync)
    end

    def finish(summary)
      exclusive('summary.json') { |file| file.write(JSON.generate(summary)) }
    end

    def close
      @out&.close
      @err&.close
    end

    private

    def exclusive(name)
      file = File.open(File.join(@path, name), File::WRONLY | File::CREAT | File::EXCL, 0o600)
      file.chmod(0o600)
      return file unless block_given?

      begin
        yield file
      ensure
        file.close
      end
    end
  end

  class HttpGuard
    ORDER = %w[auth_id_password player_get_info chat_display].freeze
    KEYS = [ %w[auth_id_password id_player password app_version cmd_id],
             %w[player_get_info id app_version session_id cmd_id],
             %w[chat_display room last_message app_version session_id cmd_id] ].freeze
    SEND_KEYS = %w[chat_send room last_message message id_player app_version session_id cmd_id].freeze
    attr_reader :rpc_count, :statuses, :name_verified, :confirmed_count, :reserved_count, :possibly_dispatched_count

    def initialize(send_count: 0, attempt: nil)
      @send_count, @attempt = send_count, attempt
      @order = ORDER + %w[chat_send chat_display] * send_count
      @rpc_count = 0
      @statuses = []
      @name_verified = false
      @cursor = ''
      @seen = {}
      @confirmed_count = @reserved_count = @possibly_dispatched_count = 0
      @awaiting_response = false
    end

    def install!
      guard = self
      @new = Net::HTTP.method(:new)
      @start = Net::HTTP.instance_method(:start)
      @request = Net::HTTP.instance_method(:request)
      original_new = @new
      original_start = @start
      original_request = @request
      Net::HTTP.singleton_class.send(:define_method, :new) do |address, port = nil, *_args|
        original_new.call(address, port, nil).tap { |http| http.verify_mode = OpenSSL::SSL::VERIFY_PEER }
      end
      # Client#request_raw starts its pool before constructing the GET. Defer
      # that start until request validation, so forbidden parameters cannot
      # even open a socket. The original request runs inside original start.
      Net::HTTP.send(:define_method, :start) do |&block|
        guard.validate_transport!(self)
        raise Stop, 'unexpected-http-start' if block

        self
      end
      Net::HTTP.send(:define_method, :request) do |request, body = nil, &block|
        raise Stop, 'destination-refused' unless body.nil?

        guard.before_request(self, request)
        guard.note_possible_dispatch!
        response = original_start.bind_call(self) do
          original_request.bind_call(self, request, body, &block)
        end
        guard.after_response(response)
        response
      rescue Net::ReadTimeout, Net::OpenTimeout, Timeout::Error
        raise Stop, 'transport-timeout'
      rescue StandardError
        raise Stop, 'transport-error'
      end
    end

    def uninstall!
      return unless @new

      original_new = @new
      Net::HTTP.singleton_class.send(:define_method, :new) { |*args, &block| original_new.call(*args, &block) }
      Net::HTTP.send(:define_method, :start, @start)
      Net::HTTP.send(:define_method, :request, @request)
    end

    def validate_transport!(http)
      valid = http.address == 'hackers-1.appspot.com' && http.port == 443 && http.use_ssl? &&
              http.verify_mode == OpenSSL::SSL::VERIFY_PEER && !http.proxy? &&
              http.open_timeout == 10 && http.read_timeout == 15 && http.write_timeout == 10 && http.max_retries == 0
      raise Stop, 'transport-refused' unless valid
    end

    def before_request(http, request)
      validate_transport!(http)
      uri = URI(request.path)
      raise Stop, 'destination-refused' unless request.method == 'GET' && request.body.nil? && uri.path == '/req.php' && !uri.host && !uri.fragment
      raise Stop, 'rpc-ceiling' if @rpc_count >= @order.length
      raise Stop, 'response-pending' if @send_count.positive? && @awaiting_response

      pairs = URI.decode_www_form(uri.query.to_s)
      params = pairs.to_h
      rpc = @order[@rpc_count]
      keys = @rpc_count < 3 ? KEYS[@rpc_count] : (rpc == 'chat_send' ? SEND_KEYS : KEYS[2])
      raise Stop, 'rpc-refused' unless pairs.length == params.length && params.keys.sort == keys.sort
      raise Stop, 'version-refused' unless params['app_version'] == '1229'
      raise Stop, 'signature-missing' unless params['cmd_id'].match?(/\A[A-Za-z0-9_.-]{8}\z/)
      flag = uri.query.split('&').find { |piece| piece.split('=').first == rpc }
      expected_flag = rpc == 'player_get_info' ? 'player_get_info=' : rpc
      raise Stop, 'flag-refused' unless flag == expected_flag

      case rpc
      when 'auth_id_password'
        raise Stop, 'identity-refused' unless params['id_player'].match?(/\A[1-9]\d*\z/) && !params['password'].empty?

        @account_id = params['id_player']
      when 'player_get_info'
        require_session!(params)
        raise Stop, 'identity-refused' unless params['id'] == @account_id
      when 'chat_display'
        require_session!(params)
        raise Stop, 'name-unverified' unless @name_verified
        raise Stop, 'room-refused' unless params['room'] == '999'
        raise Stop, 'cursor-refused' unless params['last_message'] == @cursor
        raise Stop, 'send-not-pending' if @rpc_count >= 3 && !@pending
      when 'chat_send'
        require_session!(params)
        raise Stop, 'name-unverified' unless @name_verified
        raise Stop, 'room-refused' unless params['room'] == '999'
        raise Stop, 'identity-refused' unless params['id_player'] == @account_id
        raise Stop, 'cursor-refused' unless params['last_message'] == @cursor
        index = @confirmed_count + 1
        raise Stop, 'send-not-ready' if @pending || index > @send_count || @reserved_count != @confirmed_count
        raise Stop, 'message-refused' unless params['message'] == "Test codificacion #{index}"
        @attempt.reserve_send(index)
        @reserved_count += 1
        @pending = index
      end
      @current_rpc = rpc
      @rpc_count += 1
      @awaiting_response = true
    rescue URI::InvalidURIError, ArgumentError
      raise Stop, 'request-malformed'
    end

    def note_possible_dispatch!
      @possibly_dispatched_count += 1 if @current_rpc == 'chat_send'
    end

    def after_response(response)
      status = response.code.to_i
      @statuses << status
      raise Stop, 'http-error' unless status == 200

      body = response.body.to_s.dup
      encoding = response['Content-Encoding'].to_s.downcase.strip
      body = Zlib::GzipReader.new(StringIO.new(body)).read if encoding == 'gzip'
      raise Stop, 'response-malformed' unless ['', 'identity', 'gzip'].include?(encoding)

      body.force_encoding(Encoding::UTF_8)
      raise Stop, 'response-malformed' unless body.valid_encoding?

      case @current_rpc
      when 'auth_id_password'
        fields = Hackers::Serializer.parseData(body).dig(0, 0)
        raise Stop, 'auth-malformed' unless fields.is_a?(Array) && !fields[3].to_s.empty?

        @session = fields[3]
      when 'player_get_info'
        profile = Hackers::Serializer::Profile.new(body).parse(0, 0)
        raise Stop, 'identity-refused' unless profile.id.to_s == @account_id
        raise Stop, 'name-mismatch' unless profile.name == EXPECTED_NAME

        @name_verified = true
        # Local only: CLI name --expect still performs its own exact check.
        # Pre-opening keeps one-shot read from discarding the baseline cursor.
        GAME.chat.open(999)
      when 'chat_display', 'chat_send'
        # T1 retains its original CLI validation path. Batch safety validates
        # *every* response before the imperative CLI can advance commands.
        inspect_chat!(body) if @send_count.positive?
      end
      @awaiting_response = false
    rescue StandardError
      raise Stop, 'response-malformed'
    end

    private

    def inspect_chat!(body)
      raise Stop, 'chat-malformed' if body == 'Exception' || body.start_with?('Exception,', 'Exception;')
      unless body.empty?
        section = body.split(Hackers::Serializer::Base::DELIM_SECTION_NORM, 2).first
        section.split(Hackers::Serializer::Base::DELIM_RECORD_NORM).each do |record|
          fields = record.split(Hackers::Serializer::Base::DELIM_FIELD_NORM, -1)
          valid = fields.length == 7 && fields[3].match?(/\A\d+\z/) && fields[6].match?(/\A\d+\z/)
          raise Stop, 'chat-malformed' unless valid
        end
      end
      messages = Hackers::Serializer::Chat.new(body).parse(0)
      fresh_echo = false
      messages.each do |message|
        # country is not a room field. Room provenance is the validated
        # request, and identity follows the existing conservative tuple.
        identity = [message.id, message.datetime, 999, message.message]
        fresh_echo ||= @current_rpc == 'chat_display' && @pending &&
                       message.id.to_s == @account_id && message.message == "Test codificacion #{@pending}" &&
                       !@seen.key?(identity)
        @seen[identity] = true
        @cursor = message.datetime
      end
      return unless @current_rpc == 'chat_display' && @pending

      raise Stop, 'echo-unconfirmed' unless fresh_echo

      @confirmed_count += 1
      @pending = nil
    end

    def require_session!(params)
      raise Stop, 'session-refused' if @session.to_s.empty? || params['session_id'] != @session
    end
  end

  def self.run(argv)
    summary = INITIAL.merge('statuses' => [])
    return summary if argv.empty? || argv == ['--help']

    # No command, message, script, default config or generic injection option.
    send_count = 0
    if argv.length == 7 && argv[5] == '--send-count' && argv[6].match?(/\A[1-5]\z/)
      send_count = argv[6].to_i
    end
    valid_length = argv.length == 5 || (argv.length == 7 && send_count.positive?)
    unless valid_length && argv[0] == '--live' && argv[1] == '--config' && argv[3] == '--attempt-dir' && argv[2].start_with?('/')
      return summary.merge('classification' => 'options-refused', 'cli_exit' => 1)
    end

    attempt = guard = nil
    previous_out, previous_err, previous_argv = $stdout, $stderr, ARGV.dup
    begin
      raise Stop, 'process-reuse-refused' if defined?(GAME)

      attempt = Attempt.new(argv[4])
      attempt.sync_parent! if send_count.positive?
      $stdout, $stderr = attempt.out, attempt.err
      guard = HttpGuard.new(send_count: send_count, attempt: attempt)
      guard.install!
      commands = COMMANDS + (1..send_count).flat_map { |index| ["chat say 999 Test codificacion #{index}", 'chat read 999'] }
      ARGV.replace(['-m', '-c', argv[2], *commands.flat_map { |cmd| ['-e', cmd] }, '--json'])
      begin
        load SANDBOX
        summary['cli_exit'] = 0
      rescue SystemExit => e
        summary['cli_exit'] = e.status == 0 ? 0 : 1
      end
      count = defined?(CLI_RESULTS) && CLI_RESULTS[:chat_last_read_count]
      summary['message_count'] = count if count.is_a?(Integer) && count >= 0
      complete = summary['cli_exit'] == 0 && guard.rpc_count == 3 + 2 * send_count && guard.name_verified
      summary['classification'] = if send_count.positive?
                                    complete && guard.confirmed_count == send_count ? 'batch-confirmed' : 'cli-failed'
                                  else
                                    complete ? 'read-complete' : 'cli-failed'
                                  end
    rescue Stop => e
      summary.merge!('classification' => e.classification, 'cli_exit' => 1)
    rescue StandardError => e
      error_class = case e
                    when Net::ReadTimeout, Net::OpenTimeout, Timeout::Error then 'TimeoutError'
                    when SystemCallError then 'FilesystemError'
                    else 'RuntimeError'
                    end
      summary.merge!('classification' => 'execution-error', 'error_class' => error_class, 'cli_exit' => 1)
    ensure
      guard&.uninstall!
      ARGV.replace(previous_argv)
      $stdout, $stderr = previous_out, previous_err
      if guard
        summary.merge!('rpc_count' => guard.rpc_count, 'statuses' => guard.statuses,
                       'name_verified' => guard.name_verified)
      end
      if send_count.positive?
        summary.merge!('confirmed_count' => guard&.confirmed_count || 0,
                       'reserved_count' => guard&.reserved_count || 0,
                       'possibly_dispatched_count' => guard&.possibly_dispatched_count || 0)
      end
      begin
        attempt&.finish(summary)
      rescue StandardError, Stop
        summary.merge!('classification' => 'capture-error', 'cli_exit' => 1)
      ensure
        attempt&.close
      end
    end
    summary
  end
end

if $PROGRAM_NAME == __FILE__
  summary = CliAuthenticatedChatCheck.run(ARGV)
  puts JSON.generate(summary)
  exit(summary['cli_exit'] || 0)
end
