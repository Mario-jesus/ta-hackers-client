# frozen_string_literal: true

require 'hackers/client'
require 'hackers/exceptions'
require 'cli/sandbox'
require_relative '../scripts/antiafk'

RSpec.describe 'Anti-AFK timing arguments' do
  before do
    allow(Time).to receive(:now).and_return(Time.new(2026, 11, 2, 14, 5, 9, '-03:00'))
  end

  ['0', '-1', '1.5', 'abc', '', ' 2', "2\n"].each do |invalid|
    [[invalid], ['2', invalid]].each do |args|
      it "rejects #{args.inspect} before accessing the game" do
        game = double('game')
        logger = double('logger')
        expect(game).not_to receive(:api)
        expect(game).not_to receive(:auth_minimal)
        expect(game).not_to receive(:player)
        expect(logger).to receive(:error).with('[2026-11-02 14:05:09 -03:00] Timing arguments must be positive whole-number minutes. Usage: script run antiafk [online_minutes] [offline_minutes]')
        expect(Antiafk.new(game, nil, logger, args).main).to be_nil
      end
    end
  end

  it 'rejects excess arguments before accessing the game' do
    game = double('game')
    logger = double('logger')
    expect(game).not_to receive(:api)
    expect(game).not_to receive(:auth_minimal)
    expect(game).not_to receive(:player)
    expect(logger).to receive(:error).with('[2026-11-02 14:05:09 -03:00] Expected at most two timing arguments. Usage: script run antiafk [online_minutes] [offline_minutes]')
    expect(Antiafk.new(game, nil, logger, %w[1 2 3]).main).to be_nil
  end

  [[[], 5400, 240], [[], 5400, 300], [%w[2], 120, 240], [%w[2 1], 120, 60]].each do |args, online, offline|
    it "honors #{args.inspect} with #{offline} seconds of silence and an exact online deadline" do
      client = Hackers::Client.new('127.0.0.1', 1, false, '/req', 'test', false, 1)
      api = double('api', client: client)
      allow(api).to receive(:sid=)
      game = double('game', api: api, player: double('player', load: nil))
      logger = double('logger', info: nil, error: nil)
      script = Antiafk.new(game, nil, logger, args)
      now = 0
      attempts = []
      waits = []
      allow(script).to receive(:monotonic) { now }
      if args.length < 2
        expect(script).to receive(:rand).with(240..300).and_return(offline)
      else
        expect(script).not_to receive(:rand)
      end
      allow(script).to receive(:sleep) do |seconds|
        waits << [now, seconds, client.session_paused?]
        if client.session_paused?
          expect { client.request_raw({}) }.to raise_error(Hackers::RequestError, /paused/)
        end
        now += seconds
      end
      allow(game).to receive(:auth_minimal) do
        attempts << now
        next unless client.session_paused?
        raise Hackers::RequestError.new('Auth', 'busy') if attempts.last == online + offline

        throw :done
      end
      catch(:done) { script.main }
      expect(waits.select { |_, _, paused| !paused }.sum { |_, seconds, _| seconds }).to eq(online)
      expect(waits.select { |_, _, paused| paused }).to eq([[online, offline, true], [online + offline, 10, true]])
      expect(attempts.last(2)).to eq([online + offline, online + offline + 10])
      expect(logger).to have_received(:info).with(include("scheduled disconnection after #{online / 60} minutes"))
      expect(logger).to have_received(:info).with(include("#{online / 60}-minute cycle ended"))
      expect(logger).to have_received(:info).with(include("blocked for #{offline} seconds"))
      expect(client.session_paused?).to be(false)
    end
  end
end
