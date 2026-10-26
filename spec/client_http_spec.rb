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

    ##
    # The native chat builder pre-escapes the message with Uri.EscapeDataString
    # before the URI is canonicalized, so message colons stay percent encoded
    # while last_message colons remain raw in the Uri.AbsoluteUri form.
    it 'native-escapes the chat_send message on the signed and sent URI without raw concatenation' do
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
      unsigned = '/req.php?chat_send&room=999&last_message=2026-10-05%2020:47:09.177&message=space%20plus%2B%20amp%26%20percent%25%20unicode%E2%9C%93%20colon%3A%20done&id_player=42&app_version=1229&session_id=SID1'

      expect(uri).to eq("#{unsigned}&cmd_id=#{synthetic_cmd_id(unsigned)}")
    end

    it 'leaves non-chat request form encoding unchanged' do
      client = Hackers::Client.new('127.0.0.1', 1, false, '/req.php', 'spec-salt', true, 1)
      params = { 'check_connectivity' => 1, 'value' => 'space colon: plus+ amp& percent% unicode✓' }

      expect(client.generate_uri_raw(params)).to eq("/req.php?#{URI.encode_www_form(params)}")
    end
  end

  describe 'chat message native escaping' do
    ##
    # Offline .NET 8 synthetic oracle: each message pre-escaped with
    # Uri.EscapeDataString and then canonicalized by Uri.AbsoluteUri, with the
    # documented salt/MD5 signature. All credentials below are synthetic.
    #
    # Honesty boundary: the oracle encodes the RFC 3986 escape stage exactly.
    # Oracle messages containing a literal `!` keep `%21` and messages
    # containing a literal `*` keep `%2A` in the oracle wire form because
    # modern .NET 8 canonicalization does not expose them; controlled backend
    # evidence requires the opposite in the final signed wire bytes, so the
    # final URI/signature assertions for those entries use the explicitly
    # documented backend-compatible variant.
    NATIVE_REFERENCE = [
      {
        message: 'Prueba CLI: ¡Hola! ¿Cómo estás? Aquí.',
        path: '/req.php?chat_send&room=69&last_message=&message=Prueba%20CLI%3A%20%C2%A1Hola%21%20%C2%BFC%C3%B3mo%20est%C3%A1s%3F%20Aqu%C3%AD.&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: 'dFlYafOZ'
      },
      {
        message: '[c][FFFFFF]Test [b][c][fd3421]Test A*BC [u]CLICK[/u]',
        path: '/req.php?chat_send&room=69&last_message=&message=%5Bc%5D%5BFFFFFF%5DTest%20%5Bb%5D%5Bc%5D%5Bfd3421%5DTest%20A%2ABC%20%5Bu%5DCLICK%5B%2Fu%5D&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: 'Uik72AeY'
      },
      {
        message: '[c][FFFFFF]Test [b][c][fd3421]Test A*BC [c][FFFFFF]TEST TEST [b][c][fd3421]¡A B!  [c][0000ff]¿QUIERES SABER CÓMO? >[u]HAZ CLICK AQUÍ[/u]<',
        path: '/req.php?chat_send&room=69&last_message=&message=%5Bc%5D%5BFFFFFF%5DTest%20%5Bb%5D%5Bc%5D%5Bfd3421%5DTest%20A%2ABC%20%5Bc%5D%5BFFFFFF%5DTEST%20TEST%20%5Bb%5D%5Bc%5D%5Bfd3421%5D%C2%A1A%20B%21%20%20%5Bc%5D%5B0000ff%5D%C2%BFQUIERES%20SABER%20C%C3%93MO%3F%20%3E%5Bu%5DHAZ%20CLICK%20AQU%C3%8D%5B%2Fu%5D%3C&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: 'ygjJQfuS'
      },
      {
        message: 'áéíóúñ',
        path: '/req.php?chat_send&room=69&last_message=&message=%C3%A1%C3%A9%C3%AD%C3%B3%C3%BA%C3%B1&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: '2JIR7WqW'
      },
      {
        message: '! ¡? ¿',
        path: '/req.php?chat_send&room=69&last_message=&message=%21%20%C2%A1%3F%20%C2%BF&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: '5XOPxUd4'
      },
      {
        message: 'emoji 😀',
        path: '/req.php?chat_send&room=69&last_message=&message=emoji%20%F0%9F%98%80&id_player=42&app_version=1229&session_id=OFFLINE',
        signature: 'lG_y4eL5'
      }
    ].freeze

    ##
    # Builds the client configuration used by the native oracle reference
    def native_client
      Hackers::Client.new('localhost', 1, false, '/req.php', 'offline-test-salt', false, 1)
    end

    ##
    # Builds the chat_send params used by the native oracle reference
    def native_params(message)
      {
        'chat_send' => nil,
        'room' => 69,
        'last_message' => '',
        'message' => message,
        'id_player' => 42,
        'app_version' => 1229,
        'session_id' => 'OFFLINE'
      }
    end

    ##
    # Oracle reference entries whose messages contain no literal `!` or `*`
    def plain_entries
      NATIVE_REFERENCE.reject { |entry| entry.fetch(:message).include?('!') || entry.fetch(:message).include?('*') }
    end

    ##
    # Oracle reference entries whose messages contain a literal `!` or `*`
    def punctuated_entries
      NATIVE_REFERENCE.select { |entry| entry.fetch(:message).include?('!') || entry.fetch(:message).include?('*') }
    end

    ##
    # Extracts the encoded message component of an oracle wire path
    def message_component(path)
      URI(path).query.split('&').find { |segment| segment.start_with?('message=') }.delete_prefix('message=')
    end

    ##
    # Derives the backend-compatible final wire form independently of
    # production code: percent-bang and percent-asterisk escapes inside the
    # message field only are exposed as literal characters, per controlled
    # same-account backend evidence for the observed punctuation shapes.
    def backend_compat_punctuated_path(path)
      path.split('&').map do |segment|
        segment.start_with?('message=') ? segment.gsub(/%21|%2A/, '%21' => '!', '%2A' => '*') : segment
      end.join('&')
    end

    it 'escapes message colons natively while last_message colons stay raw' do
      client = native_client
      uri = client.generate_uri_raw(
        'chat_send' => nil,
        'room' => 69,
        'last_message' => '2026-10-05 20:47:09.177',
        'message' => 'colon: done',
        'id_player' => 42,
        'app_version' => 1229,
        'session_id' => 'OFFLINE'
      )

      expect(uri).to eq(
        '/req.php?chat_send&room=69&last_message=2026-10-05%2020:47:09.177&message=colon%3A%20done&id_player=42&app_version=1229&session_id=OFFLINE'
      )
    end

    it 'matches the native reference for the message escape stage' do
      client = native_client

      NATIVE_REFERENCE.each do |entry|
        stage = client.send(:escape_chat_message, entry.fetch(:message))

        expect(stage).to eq(message_component(entry.fetch(:path)))
      end
    end

    it 'keeps the native reference URI and signature for oracle messages without a bang or asterisk' do
      client = native_client

      plain_entries.each do |entry|
        signed = client.generate_uri_cmd(native_params(entry.fetch(:message)))

        expect(signed).to eq("#{entry.fetch(:path)}&cmd_id=#{entry.fetch(:signature)}")
      end
    end

    it 'exposes the backend-compatible literal bang and star in the final wire URI for punctuated oracle messages' do
      client = native_client

      punctuated_entries.each do |entry|
        expect(client.generate_uri_raw(native_params(entry.fetch(:message))))
          .to eq(backend_compat_punctuated_path(entry.fetch(:path)))
      end
    end

    it 'escapes query injection characters like the native builder' do
      client = native_client
      uri = client.generate_uri_raw(native_params('plus+ amp& percent% hash# quest?'))

      expect(uri).to eq(
        '/req.php?chat_send&room=69&last_message=&message=plus%2B%20amp%26%20percent%25%20hash%23%20quest%3F&id_player=42&app_version=1229&session_id=OFFLINE'
      )
    end

    it 'signs the backend-compatible punctuated wire URI for oracle messages containing a bang or asterisk' do
      client = native_client

      punctuated_entries.each do |entry|
        uri = client.generate_uri_cmd(native_params(entry.fetch(:message)))
        punctuated_path = backend_compat_punctuated_path(entry.fetch(:path))

        expect(uri).to eq("#{punctuated_path}&cmd_id=#{synthetic_cmd_id(punctuated_path, 'offline-test-salt')}")
        expect(synthetic_cmd_id(punctuated_path, 'offline-test-salt')).not_to eq(entry.fetch(:signature))
      end
    end

    it 'round-trips the native message encoding back to the original text' do
      client = native_client

      NATIVE_REFERENCE.each do |entry|
        raw = client.generate_uri_raw(native_params(entry.fetch(:message)))
        decoded = URI.decode_www_form(URI(raw).query).to_h.fetch('message')

        expect(decoded).to eq(entry.fetch(:message))
        expect(decoded.valid_encoding?).to be(true)
      end
    end

    it 'exposes repeated and accented bangs literally in dedicated chat messages' do
      client = native_client
      double_bang = 'Prueba doble!! ¡!'
      accented = '¡Acentuada!'

      expect(client.generate_uri_raw(native_params(double_bang)))
        .to eq('/req.php?chat_send&room=69&last_message=&message=Prueba%20doble!!%20%C2%A1!&id_player=42&app_version=1229&session_id=OFFLINE')
      expect(client.generate_uri_raw(native_params(accented)))
        .to eq('/req.php?chat_send&room=69&last_message=&message=%C2%A1Acentuada!&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    it 'signs dedicated bang messages identically on both hash passes' do
      client = native_client
      unsigned = '/req.php?chat_send&room=69&last_message=&message=Prueba%20doble!!%20%C2%A1!&id_player=42&app_version=1229&session_id=OFFLINE'

      expect(client.generate_uri_cmd(native_params('Prueba doble!! ¡!')))
        .to eq("#{unsigned}&cmd_id=#{synthetic_cmd_id(unsigned, 'offline-test-salt')}")
    end

    it 'escapes mixed punctuation with only bangs exposed literally' do
      client = native_client

      expect(client.generate_uri_raw(native_params('A!B?C#D&E')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=A!B%3FC%23D%26E&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    ##
    # User-probed asterisk message from the controlled backend evidence round;
    # the modern-wire signature is asserted different, never equal.
    it 'exposes the user-probed literal asterisk with its independently derived signature' do
      client = native_client
      modern = '/req.php?chat_send&room=69&last_message=&message=A%2AB&id_player=42&app_version=1229&session_id=OFFLINE'
      final = '/req.php?chat_send&room=69&last_message=&message=A*B&id_player=42&app_version=1229&session_id=OFFLINE'

      expect(client.generate_uri_raw(native_params('A*B'))).to eq(final)
      expect(client.generate_uri_cmd(native_params('A*B')))
        .to eq("#{final}&cmd_id=#{synthetic_cmd_id(final, 'offline-test-salt')}")
      expect(synthetic_cmd_id(final, 'offline-test-salt')).not_to eq(synthetic_cmd_id(modern, 'offline-test-salt'))
    end

    it 'exposes repeated asterisks with bangs in dedicated messages' do
      client = native_client

      expect(client.generate_uri_raw(native_params('A**B C*!')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=A**B%20C*!&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    it 'exposes mixed asterisks bangs and accents literally together' do
      client = native_client

      expect(client.generate_uri_raw(native_params('¡A*B!')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=%C2%A1A*B!&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    ##
    # A literal `%2A`/`%21` user string is percent-escaped itself and must stay
    # escaped; only real percent-bang and percent-asterisk escape tokens from
    # the RFC 3986 stage are exposed.
    it 'preserves literal percent-marked escape sequences in user text' do
      client = native_client

      expect(client.generate_uri_raw(native_params('A%2AB')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=A%252AB&id_player=42&app_version=1229&session_id=OFFLINE')
      expect(client.generate_uri_raw(native_params('A%21!')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=A%2521!&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    it 'keeps injection punctuation escaped with only observed shapes exposed' do
      client = native_client

      expect(client.generate_uri_raw(native_params('A*B?C#D&E')))
        .to eq('/req.php?chat_send&room=69&last_message=&message=A*B%3FC%23D%26E&id_player=42&app_version=1229&session_id=OFFLINE')
    end

    ##
    # Ruby form encoding already leaves a literal `*` raw in non-message
    # fields; this correction must not change non-message or non-chat stars.
    it 'keeps non-message chat field stars in the plain canonical form' do
      client = native_client
      uri = client.generate_uri_raw(
        'chat_display' => nil, 'room' => 999, 'last_message' => '', 'filter' => 'star* filter',
        'app_version' => 1229, 'session_id' => 'OFFLINE'
      )

      expect(uri).to eq('/req.php?chat_display&room=999&last_message=&filter=star*%20filter&app_version=1229&session_id=OFFLINE')
    end

    it 'decodes the canonical bang wire form back to the original text' do
      client = native_client

      ['Prueba doble!! ¡!', 'A!B?C#D&E', '¡Acentuada!'].each do |message|
        raw = client.generate_uri_raw(native_params(message))
        decoded = URI.decode_www_form(URI(raw).query).to_h.fetch('message')

        expect(decoded).to eq(message)
      end
    end

    it 'keeps escaped bangs in non-message chat fields' do
      client = native_client
      uri = client.generate_uri_raw(
        'chat_display' => nil, 'room' => 999, 'last_message' => '', 'filter' => 'aux! filter',
        'app_version' => 1229, 'session_id' => 'OFFLINE'
      )

      expect(uri).to eq('/req.php?chat_display&room=999&last_message=&filter=aux%21%20filter&app_version=1229&session_id=OFFLINE')
    end

    it 'keeps plain form encoding for a message key outside chat requests' do
      client = native_client

      expect(client.generate_uri_raw('report_create' => '', 'message' => 'colon: done'))
        .to eq("/req.php?#{URI.encode_www_form('report_create' => '', 'message' => 'colon: done')}")
      expect(client.generate_uri_raw('report_create' => '', 'message' => 'bang!'))
        .to include('message=bang%21')
      expect(client.generate_uri_raw('report_create' => '', 'message' => 'A*B!'))
        .to include('message=A*B%21')
      expect(URI.decode_www_form('message=colon%3A+done')).to include(['message', 'colon: done'])
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
