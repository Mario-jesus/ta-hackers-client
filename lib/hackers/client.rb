# frozen_string_literal: true

require 'net/http'
require 'digest'
require 'base64'
require 'stringio'
require 'zlib'

module Hackers
  ##
  # A client to communicate with the HTTP server
  class Client
    ##
    # HTTP headers
    HEADERS = {
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Accept-Charset' => 'utf-8',
      'Accept-Encoding' => '',
      'User-Agent' => 'BestHTTP/2 v2.2.0'
    }.freeze

    ENCODING_GZIP = 'gzip'
    ENCODING_IDENTITY = 'identity'

    ##
    # Bound for header-derived error evidence, so metadata stays small
    MAX_EVIDENCE_LENGTH = 256

    ##
    # Bounded pool timeouts (seconds): no hang may outlive the CLI run
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15
    WRITE_TIMEOUT = 10

    ##
    # Net::HTTP transparently retries idempotent requests once by default,
    # which must never happen for this protocol — chat sends and names are
    # mutative and a silent duplicate changes game state.
    MAX_RETRIES = 0

    ##
    # Creates a new client
    def initialize(host, port, ssl, path, salt, compression = true, amount = 5)
      @path = path
      @salt = salt
      @compression = compression

      @headers = HEADERS.dup
      accept_encoding = [ENCODING_IDENTITY]
      accept_encoding.unshift(ENCODING_GZIP) if @compression
      @headers['Accept-Encoding'] = accept_encoding.join(', ')

      @traffic_mutex = Mutex.new
      @traffic_drained = ConditionVariable.new
      @active_requests = 0
      @cycle_owner = nil
      @session_paused = false
      @recovery = false

      @clients = {}
      amount.times do
        client = Net::HTTP.new(host, port.to_i)
        client.use_ssl = ssl
        client.open_timeout = OPEN_TIMEOUT
        client.read_timeout = READ_TIMEOUT
        client.write_timeout = WRITE_TIMEOUT
        client.max_retries = MAX_RETRIES
        @clients[client] = Mutex.new
      end
    end

    # One owner controls scheduled silence. Interrupt masking closes the gap
    # between acquiring ownership/admission and installing its ensure cleanup.
    def with_session_cycle
      Thread.handle_interrupt(Exception => :never) do
        @traffic_mutex.synchronize do
          raise RequestError.new('Session', 'anti-AFK already running') if @cycle_owner

          @cycle_owner = Thread.current
        end
        begin
          Thread.handle_interrupt(Exception => :immediate) { yield }
        ensure
          @traffic_mutex.synchronize do
            @session_paused = @recovery = false
            @cycle_owner = nil
          end
        end
      end
    end

    def session_paused?
      @traffic_mutex.synchronize { @session_paused }
    end

    # Close admission BEFORE draining. The yielded capability can only be used
    # by this owner while this pause is live; it never admits other threads.
    def with_session_pause
      raise RequestError.new('Session', 'anti-AFK owner required') unless @cycle_owner == Thread.current

      Thread.handle_interrupt(Exception => :never) do
        @traffic_mutex.synchronize do
          raise RequestError.new('Session', 'Traffic already paused') if @session_paused

          @session_paused = true
        end
        begin
          Thread.handle_interrupt(Exception => :immediate) do
            @traffic_mutex.synchronize do
              @traffic_drained.wait(@traffic_mutex) until @active_requests.zero?
            end
            recover = proc do |&operation|
              @traffic_mutex.synchronize do
                unless @cycle_owner == Thread.current && @session_paused
                  raise RequestError.new('Session', 'recovery owner required')
                end
                @recovery = true
              end
              begin
                operation.call
              ensure
                @traffic_mutex.synchronize { @recovery = false }
              end
            end
            yield recover
          end
        ensure
          @traffic_mutex.synchronize { @session_paused = @recovery = false }
        end
      end
    end

    ##
    # Generates a raw URI
    def generate_uri_raw(params)
      query = chat_request?(params) ? canonical_chat_query(params) : URI.encode_www_form(params)
      "#{@path}?#{query}"
    end

    ##
    # Generates a hashed URI
    def generate_uri_cmd(params)
      params['cmd_id'] = hash_uri(generate_uri_raw(params))
      generate_uri_raw(params)
    end

    ##
    # Generates a sessioned URI
    def generate_uri_session(params, sid)
      params['session_id'] = sid
      generate_uri_cmd(params)
    end

    ##
    # Does the raw request
    def request_raw(params, data: {})
      with_request_operation { perform_request(params, data: data) }
    end

    # Drain whole authenticated operations, including response parsing and local
    # commits, not just their HTTP portion. Nested admissions are independently
    # balanced; no transport or parsing runs while the gate mutex is held.
    def with_request_operation
      Thread.handle_interrupt(Exception => :never) do
        @traffic_mutex.synchronize do
          if @session_paused && !(@cycle_owner == Thread.current && @recovery)
            raise RequestError.new('Session', 'Traffic paused by anti-AFK; retry after recovery or stop its job')
          end
          @active_requests += 1
        end
        begin
          Thread.handle_interrupt(Exception => :immediate) { yield }
        ensure
          @traffic_mutex.synchronize do
            @active_requests -= 1
            @traffic_drained.broadcast if @active_requests.zero?
          end
        end
      end
    end

    def perform_request(params, data: {})
      client, mutex = @clients.detect { |_, v| !v.locked? }
      client, mutex = @clients.to_a.first if client.nil?

      uri = generate_uri_raw(params)
      response = nil
      mutex.synchronize do
        client.start unless client.started?
        response = data.empty? ? client.get(uri, @headers) : client.post(uri, URI.encode_www_form(data), @headers)
      rescue StandardError => e
        raise RequestError.new(e.class.to_s, e.message)
      end

      body = decode_response_body(response)

      raise error_from_response(response, body) unless response.instance_of?(Net::HTTPOK)

      body
    end

    private :perform_request

    ##
    # Does the hashed request
    def request_cmd(params, data: {})
      uri = generate_uri_raw(params)
      params['cmd_id'] = hash_uri(uri)
      request_raw(params, data: data)
    end

    ##
    # Does the sessioned request
    def request_session(params, sid, data: {})
      params['session_id'] = sid
      request_cmd(params, data: data)
    end

    private

    ##
    # Chat requests must match the native .NET Uri.AbsoluteUri form before the
    # checksum is computed. The native chatSend builder pre-escapes the message
    # with Uri.EscapeDataString, and controlled same-account backend evidence
    # requires the final signed wire bytes of the message field to expose a
    # literal `!` and `*` (see canonical_chat_message). Message colons stay
    # %3A; all other punctuation stays escaped. Every other field keeps the
    # previously verified safe subset: form encoding plus the space and colon
    # canonicalization observed in Uri.AbsoluteUri, which leaves last_message
    # colons raw.
    def canonical_chat_query(params)
      params.map { |key, value| canonical_chat_param(key, value) }.join('&')
    end

    ##
    # Builds one chat query pair in its field-specific canonical form
    def canonical_chat_param(key, value)
      name = URI.encode_www_form_component(key)
      return name if value.nil?

      value = key == 'message' ? canonical_chat_message(value) : canonical_chat_value(value)
      "#{name}=#{value}"
    end

    ##
    # Keeps the form-encoding plus observed safe subset for non-message fields
    def canonical_chat_value(value)
      URI.encode_www_form_component(value).gsub('+', '%20').gsub(/%3A/i, ':')
    end

    ##
    # Escapes one chat message with the native Uri.EscapeDataString contract:
    # RFC 3986 unreserved characters stay literal and every other character
    # becomes uppercase UTF-8 percent encoding. Applied exactly once; never
    # re-form-escaped afterwards.
    def escape_chat_message(value)
      value.to_s.gsub(/[^A-Za-z0-9\-._~]/) do |char|
        char.unpack('C*').map { |byte| format('%%%02X', byte) }.join
      end
    end

    ##
    # Final canonical form of one chat message: the RFC 3986 escape stage stays
    # intact, then the backend-compatible wire normalization below adjusts only
    # the message field before the checksum, identically on both hash passes.
    def canonical_chat_message(value)
      expose_chat_message_punctuation(escape_chat_message(value))
    end

    ##
    # Backend-compatible normalization of the final signed wire bytes:
    # controlled same-account backend evidence showed percent-bang and
    # percent-asterisk message values rejected with an empty 5-class send
    # response while the identical decoded texts published through the same
    # guarded path when the wire form carried a literal `!` or `*`. The
    # message field therefore exposes literal `!` and `*` in the wire URI as
    # an explicit two-token mapping. Modern .NET 8 Uri canonicalization does
    # not perform this exposure, so this is a backend-compatible
    # normalization, not a claimed byte-equality with the unknown native
    # final canonicalization. The mapping is intentionally not generic:
    # percent escapes of these characters themselves stay escaped, so a
    # literal user `%2A` or `%21` string (escaped as `%252A`/`%2521`) is
    # preserved, and separator characters like `? & = # / + %` remain escaped.
    def expose_chat_message_punctuation(escaped)
      escaped.gsub(/%21|%2A/, '%21' => '!', '%2A' => '*')
    end

    ##
    # Detects chat request builders whose native URI canonicalization differs
    # from ordinary form requests.
    def chat_request?(params)
      params.key?('chat_send') || params.key?('chat_display')
    end

    ##
    # Computes a hash of the URI
    def hash_uri(uri)
      data = String.new
      data << uri
      offset = data.length < 10 ? data.length : 10
      data.insert(offset, @salt)
      hash = Digest::MD5.digest(data)
      hash = Base64.strict_encode64(hash[2..7])
      hash.gsub('=', '.').gsub('+', '-').gsub('/', '_')
    end

    ##
    # Decodes the response body once. Transparently decoded responses (header
    # removed by the HTTP layer) are returned as-is to avoid a second decode.
    def decode_response_body(response)
      body = response.body.to_s
      case response['Content-Encoding'].to_s.strip.downcase
      when '', ENCODING_IDENTITY
        body.force_encoding('UTF-8')
      when ENCODING_GZIP
        inflate_gzip_body(response, body)
      else
        raise http_evidence_error(response, body, 'unsupported content encoding')
      end
    end

    ##
    # Decompresses a gzip body exactly once
    def inflate_gzip_body(response, body)
      decoded = Zlib::GzipReader.new(StringIO.new(body)).read
      decoded.force_encoding('UTF-8')
    rescue Zlib::Error, EOFError, IOError, RangeError => e
      raise http_evidence_error(response, body, "malformed gzip response body (#{safe_reason(e)})")
    end

    ##
    # Builds the error for a non-200 response. Only known game exception
    # mappings may echo body-derived type and whitelisted description; every
    # other response is replaced by a static reason plus safe HTTP evidence,
    # never arbitrary response content.
    def error_from_response(response, body)
      evidence = response_evidence(response, body)
      envelope = parse_error_envelope(body)

      return http_evidence_error(response, body, generic_reason(response, body)) unless envelope && envelope.type == EXCEPTION_TYPE

      return EXCEPTIONS[envelope.data].new(envelope.type, envelope.data, **evidence) if EXCEPTIONS.key?(envelope.data)

      RequestError.new(EXCEPTION_TYPE, nil, **evidence)
    end

    ##
    # Parses the protocol error envelope, returning nil when it is not usable
    def parse_error_envelope(body)
      return nil unless body.valid_encoding?

      Serializer::Exception.new(body).parse(0, 0)
    rescue Serializer::ParserError, EncodingError, ArgumentError
      nil
    end

    ##
    # Collects safe, bounded HTTP evidence for error metadata
    def response_evidence(response, body)
      {
        http_status: response.code.to_i,
        content_type: bounded_evidence(response['Content-Type']),
        content_encoding: bounded_evidence(response['Content-Encoding']),
        byte_count: body.bytesize
      }
    end

    ##
    # Bounds a header value for evidence: printable, capped, or withheld
    def bounded_evidence(value)
      text = value.to_s
      return nil unless text.valid_encoding?
      return nil unless text.match?(/\A[\x20-\x7E]+\z/)

      text[0, MAX_EVIDENCE_LENGTH]
    end

    ##
    # Builds a generic HTTP error carrying only safe, body-free evidence
    def http_evidence_error(response, body, reason)
      RequestError.new('HTTP', reason, **response_evidence(response, body))
    end

    ##
    # Selects a static, body-free reason for an unexpected HTTP response
    def generic_reason(response, body)
      return 'redirection response (not followed)' if response.kind_of?(Net::HTTPRedirection)
      return 'empty response body' if body.empty?

      'unexpected response body'
    end

    ##
    # Reduces a diagnostic value to bounded printable evidence
    def safe_reason(value)
      reason = value.to_s
      match = reason.match(/\A[\x20-\x7E]{1,96}/)
      match ? match[0] : "[#{value.class}]"
    end
  end

  ##
  # An exception raises when the request fails
  class RequestError < StandardError
    attr_reader :type, :description, :http_status, :content_type, :content_encoding, :byte_count

    ##
    # Creates a new exception
    def initialize(type = nil, description = nil, http_status: nil, content_type: nil, content_encoding: nil, byte_count: nil)
      super(nil)
      @type = type&.strip
      @description = description&.strip
      @http_status = http_status
      @content_type = content_type
      @content_encoding = content_encoding
      @byte_count = byte_count
    end

    ##
    # Returns the description of the exception as a string
    def to_s
      msg = String.new
      msg += @type.nil? ? 'Unknown' : @type
      msg += ": #{@description}" unless @description.nil?
      msg
    end
  end
end
