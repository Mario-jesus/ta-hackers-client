# frozen_string_literal: true

require 'hackers'

# Offline tests for the minimal authentication path (task C1).
#
# Game#auth_minimal must perform exactly one auth request, extract only the
# session id with a non-empty guard, and never trigger catalog, mission or
# profile decoding. The full Game#auth route must keep its existing behavior.
# All transport is stubbed with synthetic payloads; no real network and no
# real config files are touched.
RSpec.describe Hackers::Game do
  AUTH_PAYLOAD = '0,0,0,SIDTEST123,4,500'.freeze
  EMPTY_SID_PAYLOAD = '0,0,0,,4,500'.freeze

  subject(:game) { described_class.new({}) }

  let(:requests) { [] }

  before do
    allow(game.api.client).to receive(:request_raw) do |params, **_kwargs|
      requests << params.dup
      AUTH_PAYLOAD
    end
  end

  describe '#auth_minimal' do
    it 'sends exactly one auth request with the native flag and version' do
      game.auth_minimal

      expect(requests.length).to eq(1)
      expect(requests.first.keys).to eq(
        ['auth_id_password', 'id_player', 'password', 'app_version', 'cmd_id']
      )
      expect(requests.first['app_version']).to eq(1229)
      expect(requests.first['auth_id_password']).to be_nil
    end

    it 'stores the session id from the auth payload' do
      game.auth_minimal

      expect(game.api.sid).to eq('SIDTEST123')
      expect(game.connected?).to be(true)
    end

    it 'does not decode missions, tutorial or profile state' do
      game.auth_minimal

      expect(game.missions.data).to be_nil
      expect(game.missions).to be_empty
      expect(game.player.tutorial).to be_nil
    end

    it 'fails safely and keeps the session unset when the id is empty' do
      allow(game.api.client).to receive(:request_raw) do |params, **_kwargs|
        requests << params.dup
        EMPTY_SID_PAYLOAD
      end

      expect { game.auth_minimal }.to raise_error(Hackers::RequestError, /empty session id/)
      expect(game.api.sid).to be_nil
      expect(game.session_active?).to be(false)
      expect(requests.length).to eq(1)
    end
  end

  describe '#session_active?' do
    it 'is false without a session id' do
      expect(game.session_active?).to be(false)
    end

    it 'is false for an empty session id' do
      game.api.sid = ''

      expect(game.session_active?).to be(false)
    end

    it 'is true for a non-empty session id' do
      game.api.sid = 'SIDTEST123'

      expect(game.session_active?).to be(true)
    end
  end

  describe '#auth (full route, unchanged)' do
    it 'still decodes tutorial, rank, experience and mission data' do
      game.auth

      expect(game.api.sid).to eq('SIDTEST123')
      expect(game.player.tutorial).to eq(0)
      expect(game.player.profile.rank).to eq(4)
      expect(game.player.profile.experience).to eq(500)
      expect(requests.length).to eq(1)
    end
  end

  describe '#auth invalid session' do
    ['', nil].each do |sid|
      it "rejects #{sid.inspect} before tutorial, profile or mission mutation" do
        data = [[['0', '0', '7', sid, '4', '500']], [], []]
        allow(Hackers::Serializer).to receive(:parseData).with(AUTH_PAYLOAD).and_return(data)
        expect(game.player).not_to receive(:tutorial=)
        expect(game.player.profile).not_to receive(:rank=)
        expect(game.player.profile).not_to receive(:experience=)
        expect(game.missions).not_to receive(:data=)
        expect(game.missions).not_to receive(:parse)

        expect { game.auth }.to raise_error(Hackers::RequestError, /empty session id/)
        expect(game.api.sid).to be_nil
        expect(requests.length).to eq(1)
      end
    end
  end

  describe 'TLS inheritance and plaintext guard' do
    def pool_client_for(config)
      game = described_class.new(config)
      game.api.client.instance_variable_get(:@clients).keys.first
    end

    it 'inherits TLS for a private JSON config without an ssl key' do
      client = pool_client_for('id' => 777, 'password' => 'synthetic-pw')

      expect(client.use_ssl?).to be(true)
    end

    it 'keeps the legacy on/off string semantics' do
      expect(pool_client_for('ssl' => 'on', 'host' => '127.0.0.1').use_ssl?).to be(true)
      expect(pool_client_for('ssl' => 'OFF', 'host' => '127.0.0.1').use_ssl?).to be(false)
    end

    it 'honors explicit booleans over a custom host' do
      expect(pool_client_for('ssl' => false, 'host' => '127.0.0.1').use_ssl?).to be(false)
      expect(pool_client_for('ssl' => true, 'host' => '127.0.0.1').use_ssl?).to be(true)
    end

    it 'fails invalid ssl values instead of silently downgrading' do
      expect { described_class.new('ssl' => 'maybe', 'host' => '127.0.0.1') }
        .to raise_error(ArgumentError, /ssl/i)
      expect { described_class.new('ssl' => 42, 'host' => '127.0.0.1') }
        .to raise_error(ArgumentError, /ssl/i)
    end

    it 'refuses plaintext HTTP for the known game host before credentials leave' do
      expect { described_class.new('ssl' => 'off') }
        .to raise_error(ArgumentError, /plaintext/i)
      expect { described_class.new('ssl' => false, 'host' => 'hackers-1.appspot.com') }
        .to raise_error(ArgumentError, /plaintext/i)
    end

    it 'keeps explicit plaintext allowed for custom hosts' do
      expect { described_class.new('ssl' => false, 'host' => '127.0.0.1') }
        .not_to raise_error
    end
  end
end
