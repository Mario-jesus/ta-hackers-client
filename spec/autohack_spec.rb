# frozen_string_literal: true

require 'hackers'
require 'cli/sandbox'
require 'cli/misc'

def target_for(id, name)
  Hackers::World::Targets::Target.new(id, name, 0, 0, 0, 0, 0, nil, nil)
end

# Offline autohack script tests.
#
# All game/network behavior is replaced by strict doubles: the doubles only
# surface the documented stage methods and deny any unexpected call, so every
# row is also a negative guard against auth, player creation, purchases,
# config persistence, replay fabrication or other unexpected api/game calls.
# No real client, configuration, CLI context, game server or HTTP transport
# is loaded here. The pre-rewrite RED proof for the original draft is the
# syntax/load guard (the draft had a SyntaxError).
RSpec.describe 'Autohack script (offline contract)' do
  AUTOHACK_PATH = File.expand_path('../scripts/autohack.rb', __dir__)

  SETTINGS_NODE_KEY = 'node types'
  SETTINGS_PROGRAM_KEY = 'program types'

  ##
  # Captures all progress/error lines for sanitized-output assertions.
  class SpyLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    def log(message)
      @entries << message.to_s
    end

    alias error log
    alias info log
  end

  ##
  # Enumerable targets double with a bounded, one-shot refresh.
  class FakeTargets
    include Enumerable

    attr_reader :refreshes

    def initialize(*pages)
      @current = pages.shift || []
      @queued = pages
      @refreshes = 0
    end

    def each(&block)
      @current.each(&block)
    end

    def new
      @refreshes += 1
      @current = @queued.shift || []
      nil
    end
  end

  ScriptRig = Struct.new(
    :script, :game, :api, :logger, :trace, :targets,
    :player, :settings, :world, :sleeps
  )

  TARGET_MAIN = target_for(777001, 'DummyTarget').freeze

  ATTACK_SEQUENCE_PROFILE = Hackers::Serializer::Profile::Data.new(
    777001, 'DummyTarget', 1001, 2468, 12, 300, 21, 3, 15, 25, '4', '9'
  ).freeze

  ##
  # Builds a fresh script instance against strict stage doubles. Outcome
  # procs replay stages; anything else raises.
  def build_script!(args:, target_pages: [[TARGET_MAIN]],
                    attack_outcome: nil, update_outcome: nil,
                    finish_outcome: nil, leave_outcome: nil,
                    connected: true, own_country: '4', own_version: 2222,
                    settings_values: { SETTINGS_NODE_KEY => '7',
                                       SETTINGS_PROGRAM_KEY => '25' },
                    settings_loaded: true)
    Object.send(:remove_const, :Autohack) if Object.const_defined?(:Autohack, false)
    load AUTOHACK_PATH

    logger = SpyLogger.new
    trace = []
    sleeps = []

    api = instance_double(Hackers::API, version: own_version)

    allow(api).to receive(:attack_net) do |target|
      trace << [:attack_net, target]
      attack_outcome ? attack_outcome.call(target) : { 'profile' => ATTACK_SEQUENCE_PROFILE }
    end

    allow(api).to receive(:update_fight) do |target, data|
      trace << [:update_fight, target, data]
      update_outcome&.call(target, data)
    end

    allow(api).to receive(:finish_fight) do |target, data|
      trace << [:finish_fight, target, data]
      finish_outcome&.call(target, data)
    end

    allow(api).to receive(:leave_net) do |target|
      trace << [:leave_net, target]
      leave_outcome&.call(target)
    end

    profile = Hackers::Serializer::Profile::Data.new(
      nil, nil, 0, 0, 0, 0, 0, 0, 0, 0, own_country, nil
    )
    player = instance_double(Hackers::Network::Player, profile: profile)
    allow(player).to receive(:load)

    settings = instance_double(Hackers::AppSettings, loaded?: settings_loaded)
    allow(settings).to receive(:get) { |key| settings_values[key] }
    allow(settings).to receive(:load)

    targets = FakeTargets.new(*target_pages)
    world = instance_double(Hackers::World::World, targets: targets)
    allow(world).to receive(:load)

    game = instance_double(
      Hackers::Game,
      connected?: connected, player: player, world: world,
      api: api, app_settings: settings
    )

    script = Autohack.new(game, double('shell'), logger, Array(args))
    allow(script).to receive(:sleep) do |interval|
      sleeps << interval
      0
    end

    ScriptRig.new(
      script, game, api, logger, trace, targets, player, settings, world, sleeps
    )
  end

  describe 'load guard' do
    it 'parses scripts/autohack.rb and subclasses Sandbox::Script' do
      rig = build_script!(args: [])

      expect(Autohack < Sandbox::Script).to be(true)
      expect(rig.script).to be_a(Sandbox::Script)
    end
  end

  describe 'argument handling' do
    it 'prints usage without touching the game when args are empty' do
      rig = build_script!(args: [])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage for a count that is not a positive integer' do
      rig = build_script!(args: ['0'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage for a non-numeric count' do
      rig = build_script!(args: ['abc'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage for a percent beyond 0..100' do
      rig = build_script!(args: ['--coffers', '101', '2'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage when the timing interval is not positive' do
      rig = build_script!(args: ['--timing', '0..9', '2'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage for timing tokens that are neither conservative, fast nor MIN..MAX' do
      rig = build_script!(args: ['--timing', 'now', '2'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end

    it 'prints usage for --help without server effects' do
      rig = build_script!(args: ['--help'])

      rig.script.main

      expect(rig.logger.entries.join("\n")).to include('usage: run autohack')
      expect(rig.game).not_to have_received(:connected?)
      expect(rig.trace).to be_empty
    end
  end

  describe 'preflight' do
    it 'stops after Not connected before any player or battle call' do
      rig = build_script!(args: ['2'], connected: false)

      rig.script.main

      expect(rig.logger.entries).to include('Not connected')
      expect(rig.player).not_to have_received(:load)
      expect(rig.trace).to be_empty
    end

    it 'refuses to run against a blank version and sends nothing' do
      rig = build_script!(args: ['2'], own_version: nil)

      rig.script.main

      expect(rig.logger.entries.any? { |line| line.include?('version') }).to be(true)
      expect(rig.player).not_to have_received(:load)
      expect(rig.trace).to be_empty
    end

    it 'requires an own country before loading the world' do
      rig = build_script!(args: ['2'], own_country: nil)

      rig.script.main

      expect(rig.player).to have_received(:load)
      expect(rig.trace).to be_empty
    end

    it 'stops when app settings do not expose node and program type keys' do
      rig = build_script!(args: ['2'], settings_values: {})

      rig.script.main

      expect(rig.player).to have_received(:load)
      joined = rig.logger.entries.join("\n")
      expect(joined).to include(SETTINGS_NODE_KEY)
      expect(joined).to include(SETTINGS_PROGRAM_KEY)
      expect(rig.trace).to be_empty
    end
  end

  describe 'run-through' do
    it 'runs one target with a zero update, a 5 percent floor payload, the instance version and one leave' do
      rig = build_script!(args: ['1'])

      rig.script.main

      expect(rig.trace).to eq([
        [:attack_net, 777001],
        [:update_fight, 777001,
         { money: 0, bitcoin: 0, nodes: '', loots: '',
           success: Hackers::Network::SUCCESS_FAIL, programs: '' }],
        [:finish_fight, 777001,
         { money: 50, bitcoin: 123, nodes: '', loots: '',
           success: Hackers::Network::SUCCESS_CORE |
                    Hackers::Network::SUCCESS_RESOURCES |
                    Hackers::Network::SUCCESS_CONTROL,
           programs: '', summary: '',
           version: '2222,7,25', replay: '' }],
        [:leave_net, 777001]
      ])

      expect(rig.api).to have_received(:attack_net).exactly(:once)
      expect(rig.api).to have_received(:leave_net).exactly(:once)

      # Instance-version proof: the fake instance exposes version 2222 while
      # the default protocol constant stays 1229.
      expect(Hackers::API::VERSION).to eq(1229)
      expect(rig.logger.entries.join("\n")).to include('raw and not verified')
    end

    it 'sends the whole coffers with --coffers=100' do
      rig = build_script!(args: ['--coffers=100', '1'])

      rig.script.main

      finished = rig.trace.find { |entry| entry.first == :finish_fight }
      expect(finished[2][:money]).to eq(1001)
      expect(finished[2][:bitcoin]).to eq(2468)
    end

    it 'floors per currency without compounding for --coffers 40' do
      rig = build_script!(args: ['--coffers', '40', '1'])

      rig.script.main

      finished = rig.trace.find { |entry| entry.first == :finish_fight }
      expect(finished[2][:money]).to eq(400)
      expect(finished[2][:bitcoin]).to eq(987)
    end
  end

  describe 'timing' do
    it 'sleeps fixed per-action ranges and honors --timing fast between targets' do
      t2 = target_for(888001, 'TargetTwo')
      rig = build_script!(args: ['--timing', 'fast', '2'],
                          target_pages: [[TARGET_MAIN, t2]])

      rig.script.main

      expect(rig.sleeps.size).to eq(7)
      expect(rig.sleeps[0]).to be_between(4, 9).inclusive
      expect(rig.sleeps[1]).to be_between(35, 95).inclusive
      expect(rig.sleeps[2]).to be_between(5, 12).inclusive
      expect(rig.sleeps[3]).to be_between(15, 25).inclusive
      expect(rig.sleeps[4]).to be_between(4, 9).inclusive
      expect(rig.sleeps[6]).to be_between(5, 12).inclusive
    end

    it 'honors a custom MIN..MAX interval with --timing 30..60' do
      t2 = target_for(888001, 'TargetTwo')
      rig = build_script!(args: ['--timing', '30..60', '2'],
                          target_pages: [[TARGET_MAIN, t2]])

      rig.script.main

      expect(rig.sleeps.size).to eq(7)
      expect(rig.sleeps[3]).to be_between(30, 60).inclusive
    end
  end

  describe 'attempts and refresh' do
    t127 = target_for(127, 'BlacklistedTarget')
    t111 = target_for(111, 'TargetA')
    t222 = target_for(222, 'TargetB')
    t333 = target_for(333, 'TargetC')
    t444 = target_for(444, 'TargetD')

    it 'skips blacklisted ids, attempts each id at most once and refreshes once before stopping' do
      rig = build_script!(
        args: ['9'],
        target_pages: [[t127, t111, t222, t333], [t111, t444]]
      )

      rig.script.main

      attacked = rig.trace.select { |entry| entry.first == :attack_net }
      expect(attacked.map { |entry| entry[1] }).to eq([111, 222, 333, 444])
      expect(rig.targets.refreshes).to eq(1)
      expect(rig.logger.entries.join("\n")).to include('No actionable targets')
    end

    it 'leaves the known entry once and stops when the fight update fails after a validated attack response' do
      rig = build_script!(
        args: ['2'],
        update_outcome: proc do |_target, _data|
          raise Hackers::RequestError.new('Net::ReadTimeout', 'raw-update-body-marker')
        end
      )

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net update_fight leave_net])
      expect(rig.trace.none? { |entry| entry.first == :finish_fight }).to be(true)
      attacked = rig.trace.select { |entry| entry.first == :attack_net }
      expect(attacked.map { |entry| entry[1] }).to eq([777001])

      joined = rig.logger.entries.join("\n")
      expect(joined).to include('Hackers::RequestError')
      expect(joined).not_to include('raw-update-body-marker')
      expect(joined).not_to include('Net::ReadTimeout')
    end

    it 'stops the run without a leave or another target when the attack request outcome is uncertain' do
      rig = build_script!(
        args: ['9'],
        target_pages: [[target_for(111, 'TargetA'), target_for(222, 'TargetB')]],
        attack_outcome: proc do |_target|
          raise Hackers::RequestError.new('Net::ReadTimeout', 'raw-attack-body-marker')
        end
      )

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net])
      expect(rig.trace.none? { |entry| entry.first == :leave_net }).to be(true)

      joined = rig.logger.entries.join("\n")
      expect(joined).to include('Hackers::RequestError')
      expect(joined).to include('manual inspection')
      expect(joined).not_to include('raw-attack-body-marker')
      expect(joined).not_to include('Net::ReadTimeout')
    end

    it 'stops the run without a leave or another target when the attack response cannot be parsed' do
      rig = build_script!(
        args: ['9'],
        target_pages: [[target_for(111, 'TargetA'), target_for(222, 'TargetB')]],
        attack_outcome: proc do |_target|
          raise Hackers::Serializer::ParserError, 'malformed-profile-body'
        end
      )

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net])
      expect(rig.trace.none? { |entry| entry.first == :leave_net }).to be(true)

      joined = rig.logger.entries.join("\n")
      expect(joined).to include('Hackers::Serializer::ParserError')
      expect(joined).to include('manual inspection')
      expect(joined).not_to include('malformed-profile-body')
    end

    it 'leaves a confirmed entry once and stops when finishing fails' do
      rig = build_script!(
        args: ['2'],
        finish_outcome: proc do |_target, _data|
          raise Hackers::RequestError.new('Net::ReadTimeout', 'raw-finish-body-marker')
        end
      )

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net update_fight finish_fight leave_net])
      leaved = rig.trace.select { |entry| entry.first == :leave_net }
      expect(leaved.size).to eq(1)

      joined = rig.logger.entries.join("\n")
      expect(joined).not_to include('raw-finish-body-marker')
    end

    it 'stops without counting the target when the cleanup leave fails' do
      rig = build_script!(
        args: ['2'],
        leave_outcome: proc do |_target|
          raise Hackers::RequestError.new('Net::ReadTimeout', 'raw-leave-body-marker')
        end
      )

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net update_fight finish_fight leave_net])
      joined = rig.logger.entries.join("\n")
      expect(joined).to include('0 successful attacks')
      expect(joined).not_to include('raw-leave-body-marker')
    end
  end

  describe 'cancellation' do
    it 'makes no leave when stop is requested before any entry' do
      rig = build_script!(args: ['9'])

      rig.script.finish
      rig.script.main

      expect(rig.trace).to be_empty
      expect(rig.player).not_to have_received(:load)
    end

    it 'cancellation after a confirmed entry stops and leaves the open target once through the finish hook' do
      rig = build_script!(
        args: ['9'],
        target_pages: [[TARGET_MAIN, target_for(888001, 'TargetTwo')]]
      )
      allow(rig.api).to receive(:update_fight) do |target, data|
        rig.trace << [:update_fight, target, data]
        rig.script.finish
        nil
      end

      rig.script.main

      expect(rig.trace.map(&:first)).to eq(%i[attack_net update_fight leave_net])
      expect(rig.trace.none? { |entry| entry.first == :finish_fight }).to be(true)
      leaved = rig.trace.select { |entry| entry.first == :leave_net }
      expect(leaved.size).to eq(1)
    end

    it 'Thread.kill after a confirmed entry leaves exactly once and never starts the next target' do
      t2 = target_for(888001, 'TargetTwo')
      rig = build_script!(args: ['9'], target_pages: [[TARGET_MAIN, t2]])

      # Sleep #7 (index 6) is target 2's post-update sleep with the entry
      # confirmed: park inside it so the kill provably interrupts mid-flight
      # while no entrance mutation is pending. Controlled by two queues; no
      # real sleeps happen anywhere in the test.
      sleeper = Queue.new
      gate = Queue.new
      sleep_calls = 0
      allow(rig.script).to receive(:sleep) do |_interval|
        sleep_calls += 1
        if sleep_calls == 6
          sleeper << true
          gate.pop
        end
        0
      end

      thread = Thread.new { rig.script.main }
      reached = false
      100_000.times do
        begin
          sleeper.pop(true)
          reached = true
          break
        rescue ThreadError
          Thread.pass
        end
      end
      raise 'the script never reached the confirmed-entry sleep' unless reached

      thread.kill
      thread.join(2)

      attacked = rig.trace.select { |entry| entry.first == :attack_net }
      finished = rig.trace.select { |entry| entry.first == :finish_fight }
      leave_net = rig.trace.select { |entry| entry.first == :leave_net }
      expect(attacked.map { |entry| entry[1] }).to eq([777001, 888001])
      expect(finished.map { |entry| entry[1] }).to eq([777001])
      expect(leave_net.map { |entry| entry[1] }).to eq([777001, 888001])
    end
  end
end
