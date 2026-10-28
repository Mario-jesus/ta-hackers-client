# frozen_string_literal: true

require 'hackers'
require 'cli/sandbox'
require_relative '../scripts/antiafk'

RSpec.describe 'Anti-AFK diagnostic logs' do
  def rig(error: nil, stage: :auth)
    client = Hackers::Client.new('127.0.0.1', 1, false, '/req', 'test', false, 1)
    api = double('api', client: client)
    allow(api).to receive(:sid=)
    player = double('player', load: nil)
    game = double('game', api: api, player: player, auth_minimal: nil)
    if error
      receiver, method = stage == :auth ? [game, :auth_minimal] : [player, :load]
      allow(receiver).to receive(method).and_raise(error)
    end
    entries = []
    logger = double('logger')
    %i[info error].each { |level| allow(logger).to receive(level) { |message| entries << [level, message] } }
    script = Antiafk.new(game, nil, logger, [])
    allow(script).to receive(:sleep) { throw :done }
    [script, entries, game, player]
  end

  before do
    allow(Time).to receive(:now).and_return(Time.new(2026, 11, 2, 14, 5, 9, '-03:00'))
  end

  it 'timestamps every emitted line with local date, time and UTC offset' do
    script, entries = rig(error: Hackers::RequestError.new('SocketError', 'private-token'))
    catch(:done) { script.main }
    expect(entries.map(&:first)).to include(:info, :error)
    expect(entries).not_to be_empty
    entries.each { |_, line| expect(line).to match(/\A\[2026-11-02 14:05:09 -03:00\] /) }
    expect(entries.map(&:last).join).not_to include('private-token')
  end

  {
    'SocketError' => 'Network/transport failure: DNS lookup failed',
    'Net::OpenTimeout' => 'Network/transport failure: connection timed out',
    'Net::ReadTimeout' => 'Network/transport failure: response timed out',
    'Errno::ECONNRESET' => 'Network/transport failure: connection reset',
    'OpenSSL::SSL::SSLError' => 'TLS connection failed; server rejection unconfirmed'
  }.each do |type, expected|
    it "describes #{type} without exposing exception text" do
      script, entries = rig(error: Hackers::RequestError.new(type, "secret\nforged log"))
      catch(:done) { script.main }
      text = entries.map(&:last).join("\n")
      expect(text).to include(expected, 'authentication', 'retrying in 10 seconds')
      expect(text).not_to include('secret', 'forged log', 'Server rejected')
    end
  end

  { 401 => 'Server rejected authentication (HTTP 401)',
    403 => 'Server refused the request (HTTP 403)',
    429 => 'Server rate limited the request (HTTP 429)',
    503 => 'Server returned an error (HTTP 503)' }.each do |status, expected|
    it "describes HTTP #{status} as an observed response, not a network outage" do
      script, entries = rig(error: Hackers::RequestError.new('HTTP', 'private body', http_status: status))
      catch(:done) { script.main }
      text = entries.map(&:last).join("\n")
      expect(text).to include(expected)
      expect(text).not_to include('Network/transport failure', 'private body')
    end
  end

  it 'identifies protocol rejection and distinguishes unconfirmed authentication failures' do
    [['Exception', 'Server reported a protocol rejection'],
     ['Auth', 'Invalid authentication response; cause unconfirmed'],
     ['Player', 'Request failed; cause unconfirmed'],
     ['HTTP', 'Request failed; cause unconfirmed']].each do |type, expected|
      script, entries = rig(error: Hackers::RequestError.new(type, 'password=secret sid=secret'))
      catch(:done) { script.main }
      text = entries.map(&:last).join("\n")
      expect(text).to include(expected)
      expect(text).not_to include('secret')
    end
  end

  it 'names the failed player-load stage instead of blaming authentication' do
    script, entries = rig(error: Hackers::RequestError.new('Net::ReadTimeout'), stage: :player)
    catch(:done) { script.main }
    errors = entries.select { |level, _| level == :error }.map(&:last).join("\n")
    expect(errors).to include('player load', 'response timed out')
    expect(errors).not_to include('during authentication')
  end

  it 'reports startup success and the next authenticated maintenance interval' do
    script, entries, game, player = rig
    catch(:done) { script.main }
    expect(entries.map(&:last).join("\n")).to include('Authenticated session active', 'next maintenance in 60 seconds')
    expect(game).to have_received(:auth_minimal).once
    expect(player).to have_received(:load).once
  end

  it 'announces startup immediately and confirms activation only after authenticated player loading' do
    script, entries, game, player = rig
    allow(game).to receive(:auth_minimal) do
      expect(entries.first).to eq([:info, '[2026-11-02 14:05:09 -03:00] Anti-AFK starting; checking authentication and player load'])
      expect(entries.map(&:last).join).not_to include('Anti-AFK activated successfully')
    end
    allow(player).to receive(:load) do
      expect(entries.map(&:last).join).not_to include('Anti-AFK activated successfully')
    end
    catch(:done) { script.main }
    activation = entries.select { |_, message| message.include?('Anti-AFK activated successfully') }
    expect(activation.length).to eq(1)
    expect(activation.first).to eq([:info, '[2026-11-02 14:05:09 -03:00] Anti-AFK activated successfully; Authenticated session active; next maintenance in 60 seconds; scheduled disconnection after three hours'])
  end

  it 'does not report successful activation while startup requests are failing' do
    script, entries = rig(error: Hackers::RequestError.new('HTTP', nil, http_status: 429))
    catch(:done) { script.main }
    text = entries.map(&:last).join("\n")
    expect(text).to include('Anti-AFK starting', 'Startup failed', 'HTTP 429')
    expect(text).not_to include('Anti-AFK activated successfully')
  end

  it 'labels planned disconnection separately from failures and reports its duration' do
    script, entries = rig
    now = 0.0
    allow(script).to receive(:monotonic) { now }
    allow(script).to receive(:rand).with(240..300).and_return(240)
    allow(script).to receive(:sleep) do |seconds|
      throw :done if seconds == 240
      now += 10_800
    end
    catch(:done) { script.main }
    text = entries.map(&:last).join("\n")
    expect(text).to include('Scheduled disconnection', 'three-hour', '240 seconds', 'all tool traffic blocked')
    expect(entries.none? { |level, _| level == :error }).to be(true)
  end
end
