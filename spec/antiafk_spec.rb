# frozen_string_literal: true

require 'digest'
require 'base64'
require 'net/http'
require 'timeout'
require 'hackers/client'
require 'hackers/exceptions'
require 'cli/sandbox'
require_relative '../scripts/antiafk'

RSpec.describe 'Anti-AFK session cycle' do
  def client
    Hackers::Client.new('127.0.0.1', 1, false, '/req', 'test', false, 1)
  end

  it 'rejects outsiders and silence-owner traffic, permits only recovery, and releases on unwind' do
    c = client
    http = c.instance_variable_get(:@clients).keys.first
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body) { +'ok' }
    allow(http).to receive(:started?).and_return(true)
    expect(http).to receive(:get).once.and_return(response)
    c.with_session_cycle do
      c.with_session_pause do |recover|
        expect { c.request_raw({}) }.to raise_error(Hackers::RequestError, /paused/)
        outsider = Thread.new do
          expect { c.request_session({}, 'old') }.to raise_error(Hackers::RequestError, /paused/)
        end
        outsider.value
        recover.call { expect(c.request_cmd({})).to eq('ok') }
      end
    end
    expect { c.with_session_cycle {} }.not_to raise_error
  end

  it 'drains admitted requests before starting silence and blocks new traffic during drain' do
    c = client
    entered, release, paused = Queue.new, Queue.new, Queue.new
    http = c.instance_variable_get(:@clients).keys.first
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body) { +'ok' }
    allow(http).to receive(:started?).and_return(true)
    expect(http).to receive(:get).once { entered << true; release.pop; response }
    request = Thread.new { c.request_raw({}) }
    entered.pop(timeout: 2)
    owner = Thread.new { c.with_session_cycle { c.with_session_pause { paused << true; release.pop } } }
    # Observe the actual closed gate rather than relying on a sleep.
    Timeout.timeout(2) { Thread.pass until c.session_paused? }
    expect { c.request_raw({}) }.to raise_error(Hackers::RequestError)
    expect(paused.empty?).to be(true)
    release << true
    request.value
    paused.pop(timeout: 2)
    owner.kill.join
    expect(c.session_paused?).to be(false)
    expect { c.with_session_cycle {} }.not_to raise_error
  ensure
    request&.kill&.join
    owner&.kill&.join
  end

  it 'releases a killed draining owner without losing the admitted request accounting' do
    c = client
    entered, release = Queue.new, Queue.new
    http = c.instance_variable_get(:@clients).keys.first
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body) { +'ok' }
    allow(http).to receive(:started?).and_return(true)
    expect(http).to receive(:get).once { entered << true; release.pop; response }
    request = Thread.new { c.request_raw({}) }
    entered.pop(timeout: 2)
    owner = Thread.new { c.with_session_cycle { c.with_session_pause { raise 'drain finished too early' } } }
    Timeout.timeout(2) { Thread.pass until c.session_paused? }
    owner.kill.join
    expect(c.session_paused?).to be(false)
    release << true
    expect(request.value).to eq('ok')
    c.with_session_cycle { c.with_session_pause { expect(c.session_paused?).to be(true) } }
  ensure
    request&.kill&.join
    owner&.kill&.join
  end

  it 'rejects duplicate ownership and safely cancels an online owner' do
    c = client
    entered, release = Queue.new, Queue.new
    owner = Thread.new { c.with_session_cycle { entered << true; release.pop } }
    entered.pop(timeout: 2)
    expect { c.with_session_cycle {} }.to raise_error(Hackers::RequestError, /already/)
    owner.kill.join
    expect { c.with_session_cycle {} }.not_to raise_error
  ensure
    owner&.kill&.join
  end

  it 'keeps recovery exclusive after player-load failure and resets backoff for the next cycle' do
    c = client
    api = double('api', client: c)
    allow(api).to receive(:sid=)
    player = double('player')
    game = double('game', api: api, player: player, auth_minimal: nil)
    logger = double('logger', info: nil, error: nil)
    script = Antiafk.new(game, nil, logger, [])
    now = 0.0
    pauses, loads, delays = 0, 0, []
    allow(script).to receive(:monotonic) { now }
    allow(script).to receive(:rand).with(240..300) { pauses += 1; 240 }
    allow(script).to receive(:sleep) do |seconds|
      delays << seconds
      now += seconds == 60 ? 10_800 : seconds
    end
    allow(player).to receive(:load) do
      loads += 1
      if c.session_paused?
        outsider = Thread.new do
          expect { c.request_raw({ 'mutation' => 1 }) }.to raise_error(Hackers::RequestError)
        end
        outsider.value
        raise Hackers::RequestError.new('Player', 'busy') if [2, 4].include?(loads)
        throw :done if pauses == 2
      end
    end
    catch(:done) { script.main }
    expect(delays).to eq([60, 240, 10, 60, 240, 10])
    expect(game).to have_received(:auth_minimal).exactly(5).times
    expect(c.session_paused?).to be(false)
  end

  it 'releases drain accounting when an in-flight request is killed' do
    c = client
    entered, release = Queue.new, Queue.new
    http = c.instance_variable_get(:@clients).keys.first
    allow(http).to receive(:started?).and_return(true)
    expect(http).to receive(:get).once { entered << true; release.pop }
    request = Thread.new { c.request_raw({}) }
    entered.pop(timeout: 2)
    owner = Thread.new { c.with_session_cycle { c.with_session_pause { release << :drained } } }
    Timeout.timeout(2) { Thread.pass until c.session_paused? }
    request.kill.join
    expect(release.pop(timeout: 2)).to eq(:drained)
    owner.value
    expect { c.with_session_cycle {} }.not_to raise_error
  ensure
    request&.kill&.join
    owner&.kill&.join
  end

  it 'does not postpone the three-hour silence deadline after transient maintenance recovery' do
    c = client
    api = double('api', client: c)
    allow(api).to receive(:sid=)
    game = double('game', api: api, player: double('player', load: nil))
    script = Antiafk.new(game, nil, double('logger', info: nil, error: nil), [])
    now = 0.0
    failed_at = []
    silence_at = nil
    allow(script).to receive(:monotonic) { now }
    allow(script).to receive(:sleep) { |seconds| now += seconds }
    allow(script).to receive(:rand).with(240..300) do
      silence_at = now
      throw :done
    end
    allow(game).to receive(:auth_minimal) do
      if !c.session_paused? && [600, 1200].include?(now) && !failed_at.include?(now)
        failed_at << now
        raise Hackers::RequestError.new('Auth', 'transient')
      end
    end
    catch(:done) { script.main }
    expect(failed_at).to eq([600, 1200])
    expect(silence_at).to eq(10_800)
  end

  [false, true].each do |late_success|
    it "keeps the gate closed into scheduled silence when recovery #{late_success ? 'succeeds late' : 'keeps failing'}" do
      c = client
      api = double('api', client: c)
      allow(api).to receive(:sid=)
      game = double('game', api: api, player: double('player', load: nil))
      script = Antiafk.new(game, nil, double('logger', info: nil, error: nil), [])
      now = 0.0
      attempts, waits, silences = [], [], []
      allow(script).to receive(:monotonic) { now }
      allow(script).to receive(:rand).with(240..300) { silences << now; 240 }
      allow(script).to receive(:sleep) do |seconds|
        waits << [now, seconds, c.session_paused?]
        if seconds == 240
          count = attempts.length
          expect { c.request_raw({}) }.to raise_error(Hackers::RequestError, /paused/)
          now += seconds
          expect(attempts.length).to eq(count)
        else
          now += now.zero? ? 10_740 : seconds
        end
      end
      allow(game).to receive(:auth_minimal) do
        attempts << now
        throw :done if attempts.length > 25 || (!silences.empty? && now >= silences.first + 1200)
        next if now.zero?
        if late_success && now == 10_770
          now = 10_810 # An admitted recovery operation finishes beyond its deadline.
          next
        end
        raise Hackers::RequestError.new('Auth', 'rejected')
      end
      catch(:done) { script.main }
      expect(silences).to eq([late_success ? 10_810 : 10_800])
      expect(attempts.first(5)).to eq([0, 10_740, 10_740, 10_750, 10_770])
      expect(waits.find { |time, _, _| time == 10_770 }[1]).to eq(30) unless late_success
      expect(waits.drop(1).all? { |_, _, paused| paused }).to be(true)
      silence_start = silences.first
      expect(attempts.none? { |time| time >= silence_start && time < silence_start + 240 }).to be(true)
      recovery_waits = waits.select { |time, _, _| time >= silence_start + 240 }.map { |_, seconds, _| seconds }
      expect(recovery_waits.first(7)).to eq([10, 20, 40, 80, 160, 180, 180])
      expect(c.session_paused?).to be(false)
    end
  end

  it 'maintains authenticated presence, waits three hours, silences and retries beyond three minutes' do
    c = client
    api = double('api', client: c)
    allow(api).to receive(:sid=)
    player = double('player')
    game = double('game', api: api, player: player)
    logger = double('logger', info: nil, error: nil)
    script = Antiafk.new(game, nil, logger, [])
    now = 0.0
    sleeps = []
    attempts = 0
    loads = 0
    allow(script).to receive(:monotonic) { now }
    allow(script).to receive(:rand).with(240..300).and_return(300)
    allow(script).to receive(:sleep) do |seconds|
      sleeps << seconds
      now += seconds
    end
    allow(game).to receive(:auth_minimal) do
      attempts += 1
      if c.session_paused?
        raise Hackers::RequestError.new('Auth', 'busy') if attempts < 188
      end
    end
    allow(player).to receive(:load) do
      loads += 1
      if c.session_paused?
        expect(sleeps).to include(300, 10, 20, 40, 80, 160, 180)
        throw :done
      end
    end
    catch(:done) { script.main }
    expect(attempts).to be >= 188
    expect(loads).to be >= 180
    expect(sleeps.first(180)).to eq([60] * 180)
    expect(api).to have_received(:sid=).with(nil).at_least(:once)
    expect(c.session_paused?).to be(false)
    expect { c.with_session_cycle {} }.not_to raise_error
  end
end
