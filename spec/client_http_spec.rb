# frozen_string_literal: true

require 'base64'
require 'digest'
require 'socket'
require 'stringio'
require 'zlib'

require 'hackers/client'
require 'hackers/exceptions'
require 'hackers/serializer'

# Loopback HTTP compatibility tests for Hackers::Client.
#
# Each test binds an ephemeral TCPServer on 127.0.0.1 and serves one synthesized
# HTTP response to a real Net::HTTP client, so gzip handling, HTTP status
# retention and error mapping are exercised through the actual transport layer.
# No test contacts the game server or performs DNS lookups.
RSpec.describe 'Hackers::Client HTTP compatibility' do
  RESPONSE_REASONS = {
    200 => 'OK',
    201 => 'Created',
    302 => 'Found',
    500 => 'Internal Server Error',
    503 => 'Service Unavailable'
  }.freeze

  ##
  # Reference command hash for synthetic offline URI expectations. This asserts
  # the documented salt/MD5 contract without exercising production hash_uri.
  def synthetic_cmd_id(uri, salt = 'spec-salt')
    bytes = uri.dup
    bytes.insert([bytes.length, 10].min, salt)
    digest = Digest::MD5.digest(bytes)
    Base64.strict_encode64(digest.byteslice(2, 6)).tr('+/=', '-_.')
  end

  ##
  # Builds a raw HTTP/1.1 response with exact Content-Length and Connection: close
  def raw_http(status, headers = {}, body = '')
    response = +"HTTP/1.1 #{status} #{RESPONSE_REASONS.fetch(status)}\r\n"
    headers.each { |name, value| response << "#{name}: #{value}\r\n" }
    response << "Content-Length: #{body.bytesize}\r\n"
    response << "Connection: close\r\n\r\n"
    response << body
  end

  ##
  # Compresses a string into raw gzip bytes
  def gzip_bytes(string)
    writer = Zlib::GzipWriter.new(StringIO.new)
    writer.write(string)
    writer.close.string
  end

  ##
  # Starts a loopback server that serves one response and records the request
  def start_loopback_server(response)
    server = TCPServer.new('127.0.0.1', 0)
    requests = []
    thread = Thread.new do
      Thread.current.report_on_exception = false
      begin
        socket = server.accept
        requests << read_http_request(socket)
        socket.write(response)
        socket.close
      rescue StandardError, IOError
        nil
      end
    end
    client = timed_client(server.addr[1])
    [client, requests, thread, server]
  end

  ##
  # Reads one HTTP request from the served socket, including any POST body
  def read_http_request(socket)
    request = +''
    until request.include?("\r\n\r\n")
      return request unless wait_readable(socket, 2)

      chunk = socket.read_nonblock(4096, exception: false)
      return request if chunk == :wait_readable || chunk.nil?

      request << chunk
    end

    if (length = request[/^Content-Length: (\d+)\r\n$/im, 1])
      body_start = request.index("\r\n\r\n") + 4
      while request.bytesize - body_start < length.to_i
        return request unless wait_readable(socket, 2)

        chunk = socket.read_nonblock(4096, exception: false)
        break if chunk == :wait_readable || chunk.nil?

        request << chunk
      end
    end
    request
  end

  ##
  # Bounds socket reads so no test can hang on a misbehaving socket
  def wait_readable(socket, seconds)
    !IO.select([socket], nil, nil, seconds).nil?
  end

  ##
  # Builds a loopback client with bounded timeouts for transport failure tests
  def timed_client(port)
    client = Hackers::Client.new('127.0.0.1', port, false, '/req.php', 'spec-salt', true, 1)
    client.instance_variable_get(:@clients).each_key do |http|
      http.open_timeout = 2
      http.read_timeout = 2
    end
    client
  end

  ##
  # Serves one response to the client and yields it; guarantees socket cleanup
  def with_served_response(response)
    client, requests, thread, server = start_loopback_server(response)
    begin
      yield client, requests
    ensure
      server.close rescue nil
      thread.join(1) rescue nil
    end
  end

  ##
  # Runs a raw request and returns both the raised error and recorded requests
  def capture_request_error(response)
    error = nil
    requests = nil
    with_served_response(response) do |client, recorded|
      requests = recorded
      begin
        client.request_raw({ 'cmd' => 'test' })
      rescue Hackers::RequestError => e
        error = e
      end
    end
    [error, requests]
  end

  describe 'URI construction' do
    it 'canonicalizes chat_display spaces and colons before hashing while preserving safe escaping' do
      client = Hackers::Client.new('127.0.0.1', 1, false, '/req.php', 'spec-salt', true, 1)
      uri = client.generate_uri_cmd(
        'chat_display' => nil,
        'room' => 'global',
        'last_message' => '2026-10-05 20:47:09.177',
        'filter' => 'literal+ amp& percent% unicode✓',
        'app_version' => 1229,
        'session_id' => 'SID+1'
      )
      unsigned = '/req.php?chat_display&room=global&last_message=2026-10-05%2020:47:09.177&filter=literal%2B%20amp%26%20percent%25%20unicode%E2%9C%93&app_version=1229&session_id=SID%2B1'

      expect(uri).to eq("#{unsigned}&cmd_id=#{synthetic_cmd_id(unsigned)}")
    end

    it 'canonicalizes chat_send message spaces on the signed and sent URI without raw concatenation' do
      client = Hackers::Client.new('127.0.0.1', 1, false, '/req.php', 'spec-salt', true, 1)
      uri = client.generate_uri_cmd(
        'chat_send' => nil,
        'room' => '999',
        'last_message' => '2026-10-05 20:47:09.177',
        'message' => 'space plus+ amp& percent% unicode✓ colon: done',
        'id_player' => 42,
        'app_version' => 1229,
        'session_id' => 'SID1'
      )
      unsigned = '/req.php?chat_send&room=999&last_message=2026-10-05%2020:47:09.177&message=space%20plus%2B%20amp%26%20percent%25%20unicode%E2%9C%93%20colon:%20done&id_player=42&app_version=1229&session_id=SID1'

      expect(uri).to eq("#{unsigned}&cmd_id=#{synthetic_cmd_id(unsigned)}")
    end

    it 'leaves non-chat request form encoding unchanged' do
      client = Hackers::Client.new('127.0.0.1', 1, false, '/req.php', 'spec-salt', true, 1)
      params = { 'check_connectivity' => 1, 'value' => 'space colon: plus+ amp& percent% unicode✓' }

      expect(client.generate_uri_raw(params)).to eq("/req.php?#{URI.encode_www_form(params)}")
    end
  end

  describe 'successful responses' do
    it 'returns a plain 200 body unchanged' do
      response = raw_http(200, { 'Content-Type' => 'text/plain' }, 'profile@data;more')
      with_served_response(response) do |client, _|
        body = client.request_raw({ 'cmd' => 'test' })
        expect(body).to eq('profile@data;more')
        expect(body.encoding).to eq(Encoding::UTF_8)
      end
    end

    it 'decodes a gzipped 200 body once' do
      response = raw_http(200, { 'Content-Type' => 'text/plain', 'Content-Encoding' => 'gzip' },
                          gzip_bytes('profile@data;more'))
      with_served_response(response) do |client, _|
        body = client.request_raw({ 'cmd' => 'test' })
        expect(body).to eq('profile@data;more')
        expect(body.encoding).to eq(Encoding::UTF_8)
      end
    end

    it 'leaves an identity-encoded 200 body unchanged' do
      response = raw_http(200, { 'Content-Type' => 'text/plain', 'Content-Encoding' => 'identity' },
                          'plain-body')
      with_served_response(response) do |client, _|
        expect(client.request_raw({ 'cmd' => 'test' })).to eq('plain-body')
      end
    end

    it 'returns the decoded body for a POST request' do
      response = raw_http(200, { 'Content-Type' => 'text/plain' }, 'posted')
      with_served_response(response) do |client, requests|
        expect(client.request_raw({ 'cmd' => 'test' }, data: { 'payload' => 'x' })).to eq('posted')
        expect(requests.first).to start_with('POST /req.php?')
      end
    end
  end

  describe 'gzip failure handling' do
    it 'raises a bounded RequestError for malformed gzip' do
      response = raw_http(200, { 'Content-Type' => 'text/plain', 'Content-Encoding' => 'gzip' },
                          "\x1f\x8b not actually gzip")
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(200)
      expect(error.content_encoding).to eq('gzip')
      expect(error.byte_count).to eq("\x1f\x8b not actually gzip".bytesize)
      expect(error.to_s).to include('gzip')
      expect(error.to_s).not_to include('not actually gzip')
    end

    it 'raises a bounded RequestError for truncated gzip' do
      payload = gzip_bytes('profile@data;more')
      truncated = payload[0, payload.bytesize / 2]
      response = raw_http(200, { 'Content-Type' => 'text/plain', 'Content-Encoding' => 'gzip' }, truncated)
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(200)
      expect(error.to_s).to include('gzip')
      expect(error.to_s.valid_encoding?).to be(true)
    end
  end

  describe 'HTTP non-200 responses' do
    it 'raises RequestError with status evidence for an empty 500 body' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, '')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(500)
      expect(error.byte_count).to eq(0)
      expect(error.to_s).to be_valid_encoding
    end

    it 'does not leak parser errors for HTML error bodies' do
      response = raw_http(500, { 'Content-Type' => 'text/html' }, '<html>gone</html>')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error).not_to be_a(Hackers::Serializer::ParserError)
      expect(error.http_status).to eq(500)
      expect(error.content_type).to eq('text/html')
      expect(error.byte_count).to eq('<html>gone</html>'.bytesize)
      expect(error.to_s).not_to include('<html>')
      expect(error.to_s).not_to include('gone')
    end

    it 'does not echo arbitrary or sensitive body content in error messages' do
      response = raw_http(503, { 'Content-Type' => 'text/html' },
                          'Set-Cookie: secret-session-token-xyz')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(503)
      expect(error.to_s).not_to include('secret-session-token-xyz')
      expect(error.to_s).not_to include('Set-Cookie')
    end

    it 'raises a bounded RequestError for an invalid UTF-8 non-200 body' do
      body = "bad \xC3\x28 bytes".b
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, body)
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(500)
      expect(error.byte_count).to eq(body.bytesize)
      expect(error.to_s).to be_valid_encoding
      expect(error.to_s).not_to include("\xC3\x28".b)
    end

    it 'does not follow redirects' do
      response = raw_http(302, { 'Location' => '/nowhere', 'Content-Type' => 'text/html' }, '')
      error, requests = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(302)
      expect(requests.length).to eq(1)
    end

    it 'rejects HTTP 201 as a success response' do
      response = raw_http(201, { 'Content-Type' => 'text/plain' }, '')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(201)
      expect(error.to_s).to be_valid_encoding
    end
  end

  describe 'game error mapping' do
    it 'maps known game exceptions on non-200 responses' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, 'Exception,maximum node level reached')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::MaximumNodeLevelError)
      expect(error.type).to eq('Exception')
      expect(error.description).to eq('maximum node level reached')
      expect(error.to_s).to eq('Exception: maximum node level reached')
      expect(error.http_status).to eq(500)
    end

    it 'reports the HTTP status for gzip-encoded error envelopes' do
      response = raw_http(500, { 'Content-Type' => 'text/plain', 'Content-Encoding' => 'gzip' },
                          gzip_bytes('Exception,too many builders requested'))
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::TooManyBuilders)
      expect(error.http_status).to eq(500)
    end

    it 'does not reflect unknown exception data in error messages' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, 'Exception,secretvalue')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.type).to eq('Exception')
      expect(error.description).to be_nil
      expect(error.http_status).to eq(500)
      expect(error.to_s).to eq('Exception')
      expect(error.to_s).not_to include('secretvalue')
    end

    it 'maps the mission already finished exception' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, 'Exception,mission already finished')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::MissionAlreadyFinishedError)
      expect(error.to_s).to eq('Exception: mission already finished')
      expect(error.http_status).to eq(500)
    end

    it 'does not reflect unrecognized protocol envelopes in error messages' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, 'SomethingElse,some failure detail')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(500)
      expect(error.byte_count).to eq('SomethingElse,some failure detail'.bytesize)
      expect(error.to_s).to eq('HTTP: unexpected response body')
      expect(error.to_s).not_to include('SomethingElse')
      expect(error.to_s).not_to include('some failure detail')
    end

    it 'does not reflect arbitrary single-field bodies in error messages' do
      response = raw_http(500, { 'Content-Type' => 'text/plain' }, 'Maintenance')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(500)
      expect(error.to_s).to eq('HTTP: unexpected response body')
      expect(error.to_s).not_to include('Maintenance')
    end

    it 'bounds header metadata evidence for non-200 responses' do
      headers = { 'Content-Type' => "text/plain; padding=#{'A' * 300}", 'Content-Encoding' => 'identity' }
      response = raw_http(500, headers, '')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.content_type).to start_with('text/plain')
      expect(error.content_type.length).to eq(256)
      expect(error.content_type).to match(/\A[\x20-\x7E]+\z/)
      expect(error.content_encoding).to eq('identity')
    end

    it 'does not reflect unsupported encoding header values in error messages' do
      headers = { 'Content-Type' => 'text/plain', 'Content-Encoding' => "br#{'A' * 300}" }
      response = raw_http(500, headers, 'payload text')
      error, _ = capture_request_error(response)
      expect(error).to be_a(Hackers::RequestError)
      expect(error.http_status).to eq(500)
      expect(error.content_encoding).to start_with('br')
      expect(error.content_encoding.length).to eq(256)
      expect(error.content_encoding).to match(/\A[\x20-\x7E]+\z/)
      expect(error.to_s).not_to include('AAAA')
    end
  end

  describe 'transport errors' do
    it 'wraps connection failures as RequestError' do
      unused = TCPServer.new('127.0.0.1', 0)
      port = unused.addr[1]
      unused.close
      client = timed_client(port)
      expect { client.request_raw({ 'cmd' => 'test' }) }.to raise_error(Hackers::RequestError)
    end

    it 'wraps premature connection close as RequestError' do
      server = TCPServer.new('127.0.0.1', 0)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          socket = server.accept
          socket.close
        rescue StandardError, IOError
          nil
        end
      end
      client = timed_client(server.addr[1])
      begin
        expect { client.request_raw({ 'cmd' => 'test' }) }.to raise_error(Hackers::RequestError)
      ensure
        server.close rescue nil
        thread.join(1) rescue nil
      end
    end
  end

  describe 'request headers' do
    it 'sends the expected protocol headers' do
      response = raw_http(200, { 'Content-Type' => 'text/plain' }, 'ok')
      with_served_response(response) do |client, requests|
        client.request_raw({ 'cmd' => 'test' })
        request = requests.first
        expect(request).to start_with('GET /req.php?')
        expect(request).to include('Content-Type: application/x-www-form-urlencoded')
        expect(request).to include('Accept-Charset: utf-8')
        expect(request).to include('Accept-Encoding: gzip, identity')
        expect(request).not_to match(/^(Authorization|Cookie):/im)
      end
    end
  end

  describe 'RequestError compatibility' do
    it 'keeps positional initialize arguments working' do
      error = Hackers::RequestError.new('Exception', 'maximum node level reached')
      expect(error.type).to eq('Exception')
      expect(error.description).to eq('maximum node level reached')
      expect(error.to_s).to eq('Exception: maximum node level reached')
    end

    it 'allows legacy no-argument initialization' do
      error = Hackers::RequestError.new
      expect(error.type).to be_nil
      expect(error.to_s).to eq('Unknown')
    end

    it 'exposes optional HTTP metadata as readers' do
      error = Hackers::RequestError.new('HTTP', 'Unexpected response body',
                                        http_status: 502, content_type: 'text/html',
                                        content_encoding: 'gzip', byte_count: 17)
      expect(error.type).to eq('HTTP')
      expect(error.http_status).to eq(502)
      expect(error.content_type).to eq('text/html')
      expect(error.content_encoding).to eq('gzip')
      expect(error.byte_count).to eq(17)
    end
  end

  describe 'pool construction settings' do
    def pool_for(ssl, amount = 1)
      client = Hackers::Client.new('127.0.0.1', 4_043, ssl, '/req.php', 'spec-salt', true, amount)
      [client, client.instance_variable_get(:@clients).keys.first]
    end

    it 'bounds timeouts and disables transparent transport retries at construction' do
      _client, http = pool_for(false)

      expect(http.max_retries).to eq(0)
      expect(http.open_timeout).to eq(10)
      expect(http.read_timeout).to eq(15)
      expect(http.write_timeout).to eq(10)
    end

    it 'keeps the requested pool size and per-client mutexes' do
      client, = pool_for(false, 3)
      pool = client.instance_variable_get(:@clients)

      expect(pool.length).to eq(3)
      expect(pool.values).to all(be_a(Mutex))
    end

    it 'preserves explicit TLS on the constructed pool' do
      _client, http = pool_for(true)

      expect(http.use_ssl?).to be(true)
    end
  end
end
