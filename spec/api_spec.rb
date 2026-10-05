# frozen_string_literal: true

require 'json'
require 'uri'
require 'digest'
require 'base64'

require 'hackers/api'
require 'hackers/client'
require 'hackers/exceptions'

# Offline API request-construction tests.
#
# All values are synthetic/dummy credentials. Expectations describe ONLY this
# repository's documented request-construction semantics (URI.encode_www_form
# plus the in-repo URI hash) and the offline native-evidence alignment:
# valueless `auth_id_password` flag (no `=`) and protocol version 1229.
# They are NOT a native cross-proof and NOT server acceptance evidence.
# No test contacts the game server: HTTP-bound client methods are replaced by
# a recorder while the real offline encoding/hash methods still run.
RSpec.describe Hackers::API do
  DEFAULT_CONFIG = 'configs/default.conf'
  NATIVE_VERSION = 1229

  # Dummy credentials only — never real account data.
  DUMMY_ID = 1_234_567
  DUMMY_PASSWORD = 'pw&=#+ x✓'
  DUMMY_SID = 'SID1'

  # Frozen wire fixtures, independently computed with the documented in-repo
  # hash derivation (salt inserted at offset 10, MD5, Base64 of bytes 2..7,
  # '=', '+', '/' remapped). Each covers the exact parameter order.
  AUTH_WIRE =
    'auth_id_password&id_player=1234567&password=pw%26%3D%23%2B+x%E2%9C%93&app_version=1229&cmd_id=vFzNqf8Q'
  LANGUAGE_WIRE =
    'i18n_translations_get_language=1&language_code=en&app_version=1229&cmd_id=h-x2JmR6'
  APP_SETTINGS_WIRE =
    'app_setting_get_list=1&app_version=1229&cmd_id=4eCTwKVb'
  NODE_TYPES_WIRE =
    'get_node_types_and_levels=1&app_version=1229&cmd_id=AAPcwNji'
  PROGRAM_TYPES_WIRE =
    'get_program_types_and_levels=1&app_version=1229&cmd_id=FPJMDMAk'
  SESSION_WIRE =
    'net_get_for_maintenance=1&id_player=1234567&app_version=1229&session_id=SID1&cmd_id=NbW3hfrS'
  CONNECTIVITY_WIRE =
    'check_connectivity=1&app_version=1229&cmd_id=zHobAvo-'
  CHAT_ROOM = 'global'
  CHAT_LAST = '42'
  CHAT_MESSAGE = 'hello & goodbye'

  # Strip the recorded cmd_id to rebuild the exact hashed URI. This only
  # removes the hash entry; every other parameter stays in its sent order.
  def canonical_wire(params)
    query = URI.encode_www_form(params)
    if params.key?('chat_send') || params.key?('chat_display')
      query = query.gsub('+', '%20').gsub(/%3A/i, ':')
    end
    query
  end

  def hashed_uri(params)
    stripped = params.reject { |key, _| key == 'cmd_id' }
    "/req.php?#{canonical_wire(stripped)}"
  end

  # Reference implementation of the documented in-repo hash. Used to verify
  # that recorded cmd_id values match the canonical formula for synthetic
  # URIs; not a native implementation copy.
  def reference_cmd_id(uri)
    data = uri.dup
    offset = data.length < 10 ? data.length : 10
    data.insert(offset, 'ZqQxXFFy')
    hash = Digest::MD5.digest(data)
    Base64.strict_encode64(hash[2..7]).gsub('=', '.').gsub('+', '-').gsub('/', '_')
  end

  subject(:api) { described_class.new(**options) }

  let(:options) { {} }
  let(:requests) { [] }

  before do
    allow(api.client).to receive(:request_raw) do |params, **_kwargs|
      requests << params.dup
      '1'
    end
  end

  shared_examples 'sends the expected wire request' do |expected_wire|
    it 'sends parameters in the expected order with the expected encoding' do
      expect(URI.encode_www_form(requests.first)).to eq(expected_wire)
    end
  end

  describe 'protocol version' do
    it 'defaults to the native 1229 wire version' do
      expect(Hackers::API::VERSION).to eq(NATIVE_VERSION)
    end

    it 'ships version 1229 in the default configuration' do
      config = JSON.parse(File.read(DEFAULT_CONFIG))
      expect(config['version']).to eq(NATIVE_VERSION)
    end

    it 'emits app_version from the default instance' do
      api.check_connectivity
      expect(requests.first['app_version']).to eq(NATIVE_VERSION)
    end

    context 'with an overridden version' do
      let(:options) { { version: 1227 } }

      it 'passes the overridden version without hardcoding' do
        api.app_settings
        expect(requests.first['app_version']).to eq(1227)
      end

      it 'hashes the overridden version URI consistently' do
        api.app_settings
        expect(requests.first['cmd_id'])
          .to eq(reference_cmd_id(hashed_uri(requests.first)))
      end

      it 'accepts an arbitrary custom version' do
        custom = described_class.new(version: 99_999)
        allow(custom.client).to receive(:request_raw) do |params, **_kwargs|
          requests << params.dup
          '1'
        end
        custom.program_types
        expect(URI.encode_www_form(requests.first)).to include('app_version=99999')
      end
    end
  end

  describe 'authentication request' do
    before do
      api.id = DUMMY_ID
      api.password = DUMMY_PASSWORD
      api.auth
    end

    it_behaves_like 'sends the expected wire request', AUTH_WIRE

    it 'sends the valueless auth_id_password flag without = separator' do
      expect(requests.first.keys.first).to eq('auth_id_password')
      expect(requests.first['auth_id_password']).to be_nil
    end

    it 'orders auth parameters as native build does' do
      expect(requests.first.keys).to eq(
        ['auth_id_password', 'id_player', 'password', 'app_version', 'cmd_id']
      )
    end

    it 'does not leak credentials and does not match native raw concatenation' do
      wire = URI.encode_www_form(requests.first)
      expect(wire).not_to include(DUMMY_PASSWORD)
      expect(wire).not_to include('pw&')
    end
  end

  describe 'credential escaping' do
    before do
      api.id = DUMMY_ID
      api.password = DUMMY_PASSWORD
      api.auth
    end

    it 'escapes reserved characters so they cannot inject query parameters' do
      expect(requests.first.keys).to eq(
        ['auth_id_password', 'id_player', 'password', 'app_version', 'cmd_id']
      )
    end

    it 'encodes space as + and literal + as %2B' do
      expect(URI.encode_www_form(requests.first)).to include('password=pw%26%3D%23%2B+x')
    end

    it 'encodes each reserved character with percent escapes' do
      password = requests.first['password']
      expect(password).to eq(DUMMY_PASSWORD)
      expect(URI.encode_www_form('password' => password)).to include('password=pw%26%3D%23%2B+x%E2%9C%93')
    end
  end

  describe 'authentication signature' do
    before do
      api.id = DUMMY_ID
      api.password = DUMMY_PASSWORD
      api.auth
    end

    it 'matches the reference hash calculation for the synthetic auth URI' do
      expect(requests.first['cmd_id']).to eq(reference_cmd_id(hashed_uri(requests.first)))
    end

    it 'matches the frozen independently computed cmd_id' do
      expect(requests.first['cmd_id']).to eq('vFzNqf8Q')
    end

    it 'omits session_id entirely because sid is nil' do
      expect(requests.first.key?('session_id')).to be(false)
    end
  end

  describe 'sessioned request' do
    let(:options) { { version: NATIVE_VERSION } }

    before do
      api.id = DUMMY_ID
      api.sid = DUMMY_SID
      api.net
    end

    it_behaves_like 'sends the expected wire request', SESSION_WIRE

    it 'places session_id before cmd_id in insertion order' do
      keys = requests.first.keys
      expect(keys.index('session_id')).to be < keys.index('cmd_id')
    end

    it 'hashes the URI including session_id' do
      expect(requests.first['cmd_id']).to eq(reference_cmd_id(hashed_uri(requests.first)))
    end
  end

  describe 'chat request flags' do
    before do
      api.id = DUMMY_ID
      api.sid = DUMMY_SID
    end

    it 'sends chat_display as a valueless flag while preserving parameter order and session hash' do
      api.read_chat(CHAT_ROOM, CHAT_LAST)

      expect(requests.first.keys).to eq(
        ['chat_display', 'room', 'last_message', 'app_version', 'session_id', 'cmd_id']
      )
      expect(requests.first['chat_display']).to be_nil
      expect(canonical_wire(requests.first)).to start_with(
        'chat_display&room=global&last_message=42&app_version=1229&session_id=SID1&cmd_id='
      )
      expect(requests.first['cmd_id']).to eq(reference_cmd_id(hashed_uri(requests.first)))
    end

    it 'sends chat_send as a valueless flag while preserving parameter order and session hash' do
      api.write_chat(CHAT_ROOM, CHAT_MESSAGE, CHAT_LAST)

      expect(requests.first.keys).to eq(
        ['chat_send', 'room', 'last_message', 'message', 'id_player', 'app_version', 'session_id', 'cmd_id']
      )
      expect(requests.first['chat_send']).to be_nil
      expect(canonical_wire(requests.first)).to start_with(
        'chat_send&room=global&last_message=42&message=hello%20%26%20goodbye&id_player=1234567&app_version=1229&session_id=SID1&cmd_id='
      )
      expect(requests.first['cmd_id']).to eq(reference_cmd_id(hashed_uri(requests.first)))
    end
  end

  describe 'public catalog commands (default configuration)' do
    it 'constructs the language_translations request for en' do
      api.language_translations
      expect(URI.encode_www_form(requests.first)).to eq(LANGUAGE_WIRE)
    end

    it 'constructs the app_settings request' do
      api.app_settings
      expect(URI.encode_www_form(requests.first)).to eq(APP_SETTINGS_WIRE)
    end

    it 'constructs the node_types request' do
      api.node_types
      expect(URI.encode_www_form(requests.first)).to eq(NODE_TYPES_WIRE)
    end

    it 'constructs the program_types request' do
      api.program_types
      expect(URI.encode_www_form(requests.first)).to eq(PROGRAM_TYPES_WIRE)
    end

    it 'constructs the check_connectivity request and converts the response' do
      expect(api.check_connectivity).to eq(1)
      expect(URI.encode_www_form(requests.first)).to eq(CONNECTIVITY_WIRE)
    end

    it 'builds catalog commands without session ids' do
      api.app_settings
      expect(requests.first.key?('session_id')).to be(false)
    end

    context 'with an explicit language override' do
      it 'uses the requested language code' do
        api.language_translations('fr')
        expect(requests.first['language_code']).to eq('fr')
        expect(requests.first['cmd_id'])
          .to eq(reference_cmd_id(hashed_uri(requests.first)))
      end
    end
  end

  describe 'rename request (set_name_once, current wire fixture preserved)' do
    EXACT_RENAME_NAME = '[ff0000]βℓąȼЌhąţhąȼЌ€я'

    before do
      api.id = DUMMY_ID
      api.sid = DUMMY_SID
      api.set_name_once(EXACT_RENAME_NAME)
    end

    it 'sends the empty-value player_set_name_once flag exactly as the current fixture does' do
      # The rename route keeps its current empty-string flag (emitted with an
      # '=' on the wire). It does NOT inherit the valueless nil-flag form of
      # auth_id_password, and the wire is left unchanged.
      expect(requests.first.keys.first).to eq('player_set_name_once')
      expect(requests.first['player_set_name_once']).to eq('')

      wire = URI.encode_www_form(requests.first)
      expect(wire).to start_with('player_set_name_once=&')
    end

    it 'keeps the exact Unicode name value without strip or normalization' do
      expect(requests.first['name']).to eq(EXACT_RENAME_NAME)
    end

    it 'round-trips the name through the encoded wire form' do
      wire = URI.encode_www_form(requests.first)

      expect(URI.decode_www_form(wire).to_h['name']).to eq(EXACT_RENAME_NAME)
    end

    it 'orders parameters as the native rename route does' do
      expect(requests.first.keys).to eq(
        ['player_set_name_once', 'id', 'name', 'app_version', 'session_id', 'cmd_id']
      )
    end

    it 'hashes the sessioned rename URI consistently' do
      expect(requests.first['cmd_id']).to eq(reference_cmd_id(hashed_uri(requests.first)))
    end

    it 'sends the session id before the command hash' do
      keys = requests.first.keys
      expect(keys.index('session_id')).to be < keys.index('cmd_id')
    end
  end
end
