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

    ##
    # Generates a raw URI
    def generate_uri_raw(params)
      query = URI.encode_www_form(params)
      query = canonical_chat_query(query) if chat_request?(params)
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
    # checksum is computed: form-encode safely first, then expose only the
    # observed safe subset of space and colon differences.
    def canonical_chat_query(query)
      query.gsub('+', '%20').gsub(/%3A/i, ':')
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
