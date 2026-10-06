# frozen_string_literal: true

require 'hackers'

RSpec.describe 'CLI connect (offline context)' do
  BOOTSTRAP = %i[language_translations app_settings node_types program_types missions_list
                 skin_types hints_list experience_list builders_list].freeze
  POST_AUTH = %i[goal_types shield_types rank_list].freeze
  LABELS = ['Language translations', 'Application settings', 'Node types', 'Program types',
            'Missions list', 'Skin types', 'Hints list', 'Experience list', 'Builders list',
            'Authenticate', 'Goal types', 'Shield types', 'Rank list'].freeze

  class FakeShell
    attr_reader :commands

    def initialize
      @commands = {}
    end

    def add_context(*)
      self
    end

    def add_command(name, **, &block)
      @commands[name] = block
      self
    end

    def completion(&block); end
  end

  let(:events) { [] }
  let(:logs) { [] }
  let(:errors) { [] }
  let(:minimal) { false }
  let(:failure_step) { nil }
  let(:failure) { Hackers::RequestError.new('Fake', 'failed') }
  let(:shell) { FakeShell.new }

  def connect
    game = Object.new
    session = nil
    (BOOTSTRAP + POST_AUTH).each do |name|
      dataset = Object.new
      # Capture example values rather than resolving methods on the fake dataset.
      recorded, failing, exception = events, failure_step, failure
      dataset.define_singleton_method(:load) do
        recorded << [name, session]
        raise exception if failing == name
      end
      game.define_singleton_method(name) { dataset }
    end
    recorded, failing, exception = events, failure_step, failure
    %i[auth auth_minimal].each do |name|
      game.define_singleton_method(name) do
        recorded << [name, session]
        raise exception if failing == name
        session = 'SYNTHETIC'
      end
    end
    logger = Object.new
    messages, failures = logs, errors
    logger.define_singleton_method(:log) { |message| messages << message }
    logger.define_singleton_method(:error) { |message| failures << message }
    context = Module.new
    context.const_set(:SHELL, shell)
    context.const_set(:GAME, game)
    context.const_set(:LOGGER, logger)
    context.const_set(:MINIMAL_CONNECT, minimal)
    # Root checks Object for the mode flag; keep this lookup local, not global.
    lookup = Object.new
    lookup.define_singleton_method(:const_defined?) { |name| name == :MINIMAL_CONNECT }
    context.const_set(:Object, lookup)
    path = File.expand_path('../lib/cli/context/root.rb', __dir__)
    context.module_eval(File.read(path), path)
    shell.commands.fetch(:connect).call(['connect'], shell)
  end

  it 'loads nine bootstrap catalogs, authenticates once, then loads session catalogs' do
    connect
    expect(events).to eq(BOOTSTRAP.map { |name| [name, nil] } + [[:auth, nil]] +
                         POST_AUTH.map { |name| [name, 'SYNTHETIC'] })
    expect(logs).to eq(LABELS)
    expect(errors).to be_empty
  end

  context 'minimal mode' do
    let(:minimal) { true }

    it 'only authenticates minimally without catalogs, profile or world calls' do
      connect
      expect(events).to eq([[:auth_minimal, nil]])
      expect(logs).to eq(['Authenticate'])
      expect(errors).to be_empty
    end
  end

  { app_settings: 'Application settings', auth: 'Authenticate',
    goal_types: 'Goal types', shield_types: 'Shield types' }.each do |step, label|
    context "when #{step} fails" do
      let(:failure_step) { step }

      it 'stops at that step and attributes the error to it' do
        connect
        order = BOOTSTRAP + [:auth] + POST_AUTH
        expect(events.map(&:first)).to eq(order.take(order.index(step) + 1))
        expect(logs).to eq(LABELS.take(order.index(step)))
        expect(errors).to eq(["#{label} (#{failure})"])
      end
    end
  end

  context 'structural parsing failure' do
    let(:failure_step) { :app_settings }
    let(:failure) { Hackers::Serializer::ParserError.new('malformed') }

    it 'propagates rather than swallowing structural errors' do
      expect { connect }.to raise_error(Hackers::Serializer::ParserError)
      expect(events.map(&:first)).to eq(BOOTSTRAP.take(2))
      expect(errors).to be_empty
    end
  end
end
