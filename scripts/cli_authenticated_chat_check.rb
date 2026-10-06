#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'stringio'
require 'zlib'
require_relative '../lib/hackers/serializer'

# Read-only, one-process authorization boundary. No config is read here:
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
    attr_reader :rpc_count, :statuses, :name_verified

    def initialize
      @rpc_count = 0
      @statuses = []
      @name_verified = false
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
        guard.before_request(self, request)
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
      raise Stop, 'destination-refused' unless request.method == 'GET' && uri.path == '/req.php' && !uri.host && !uri.fragment
      raise Stop, 'rpc-ceiling' if @rpc_count >= ORDER.length

      pairs = URI.decode_www_form(uri.query.to_s)
      params = pairs.to_h
      rpc = ORDER[@rpc_count]
      raise Stop, 'rpc-refused' unless pairs.length == params.length && params.keys.sort == KEYS[@rpc_count].sort
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
        raise Stop, 'room-refused' unless params['room'] == '999' && params['last_message'] == ''
      end
      @current_rpc = rpc
      @rpc_count += 1
    rescue URI::InvalidURIError, ArgumentError
      raise Stop, 'request-malformed'
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
      end
    rescue StandardError
      raise Stop, 'response-malformed'
    end

    private

    def require_session!(params)
      raise Stop, 'session-refused' if @session.to_s.empty? || params['session_id'] != @session
    end
  end

  def self.run(argv)
    summary = INITIAL.merge('statuses' => [])
    return summary if argv.empty? || argv == ['--help']

    # No command, message, script, default config or generic injection option.
    unless argv.length == 5 && argv[0] == '--live' && argv[1] == '--config' && argv[3] == '--attempt-dir' && argv[2].start_with?('/')
      return summary.merge('classification' => 'options-refused', 'cli_exit' => 1)
    end

    attempt = guard = nil
    previous_out, previous_err, previous_argv = $stdout, $stderr, ARGV.dup
    begin
      raise Stop, 'process-reuse-refused' if defined?(GAME)

      attempt = Attempt.new(argv[4])
      $stdout, $stderr = attempt.out, attempt.err
      guard = HttpGuard.new
      guard.install!
      ARGV.replace(['-m', '-c', argv[2], *COMMANDS.flat_map { |cmd| ['-e', cmd] }, '--json'])
      begin
        load SANDBOX
        summary['cli_exit'] = 0
      rescue SystemExit => e
        summary['cli_exit'] = e.status == 0 ? 0 : 1
      end
      count = defined?(CLI_RESULTS) && CLI_RESULTS[:chat_last_read_count]
      summary['message_count'] = count if count.is_a?(Integer) && count >= 0
      summary['classification'] = summary['cli_exit'] == 0 && guard.rpc_count == 3 && guard.name_verified ? 'read-complete' : 'cli-failed'
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
