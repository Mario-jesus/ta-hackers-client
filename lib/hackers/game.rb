# frozen_string_literal: true

module Hackers
  ##
  # Game API implementation
  class Game
    attr_reader :api, :app_settings, :node_types,
                :language_translations, :program_types,
                :missions_list, :skin_types, :player,
                :chat, :hints_list, :experience_list,
                :builders_list, :goal_types, :shield_types,
                :rank_list, :countries_list, :world,
                :missions, :news_list, :ranking_list

    attr_accessor :config

    def initialize(config)
      @config = config

      api_config = {}
      api_config[:host] = @config['host'] if @config.key?('host')
      api_config[:port] = @config['port'] if @config.key?('port')
      api_config[:path] = @config['url'] if @config.key?('url')
      api_config[:salt] = @config['salt'] if @config.key?('salt')
      api_config[:version] = @config['version'] if @config.key?('version')
      api_config[:language] = @config['language'] if @config.key?('language')
      api_config[:platform] = @config['platform'] if @config.key?('platform')
      api_config[:compression] = @config['compression'] if @config.key?('compression')

      # Absence of the ssl key inherits the default TLS setting; a private
      # id/password config must never silently fall back to plaintext.
      api_config[:ssl] = resolve_ssl

      # Plaintext HTTP is refused for the known game host before any
      # credential leaves the process; explicit plaintext stays possible for
      # custom/loopback hosts.
      if api_config[:ssl] == false && config_host == API::HOST
        raise ArgumentError, 'Plaintext HTTP is not allowed for the game server'
      end

      @api = API.new(**api_config)
      @api.id = @config['id']
      @api.password = @config['password']

      @countries_list = CountriesList.new(@api)
      @app_settings = AppSettings.new(@api)
      @language_translations = LanguageTranslations.new(@api)
      @node_types = NodeTypes::List.new(@api)
      @program_types = ProgramTypes::List.new(@api)
      @missions_list = MissionsList.new(@api)
      @skin_types = SkinTypes.new(@api)
      @hints_list = HintsList.new(@api)
      @experience_list = ExperienceList.new(@api)
      @builders_list = BuildersList.new(@api)
      @goal_types = GoalTypes.new(@api)
      @shield_types = ShieldTypes.new(@api)
      @rank_list = RankList.new(@api)
      @player = Network::Player.new(@api)
      @world = World::World.new(@api, self)
      @chat = Chat.new(@api)
      @missions = Missions.new(@api, @player)
      @news_list = NewsList.new(@api)
      @ranking_list = RankingList.new(@api, @player)
    end

    ##
    # Returns true if there is an API session id
    def connected?
      @api.sid?
    end

    ##
    # Returns true when a non-empty API session id is present
    def session_active?
      @api.sid? && !@api.sid.to_s.empty?
    end

    ##
    # Authenticates by id and password without catalog, mission or profile
    # decoding: exactly one auth request, only the session id is extracted
    def auth_minimal
      raw_data = @api.auth
      data = Serializer.parseData(raw_data)

      sid = data.dig(0, 0, 3)
      if sid.nil? || sid.to_s.empty?
        raise Hackers::RequestError.new('Auth', 'empty session id')
      end

      @api.sid = sid
    end

    ##
    # Authenticates by id and password
    def auth
      raw_data = @api.auth
      data = Serializer.parseData(raw_data)

      @player.tutorial = data.dig(0, 0, 2).to_i
      @api.sid = data.dig(0, 0, 3)
      @player.profile.rank = data.dig(0, 0, 4).to_i
      @player.profile.experience = data.dig(0, 0, 5).to_i

      @missions.data = data[2]
      @missions.parse
    end

    ##
    # Attacks target in test mode
    def attack_test(id)
      target = Network::Target.new(@api)
      target.attack_test(id)
      target
    end

    ##
    # Returns friend dataset
    def friend(id)
      Network::Friend.new(@api, id)
    end

    ##
    # Buys a skin
    def buy_skin(skin)
      @api.buy_skin(skin)
    end

    ##
    # Buys a shield
    def buy_shield(shield)
      @api.buy_shield(shield)
    end

    ##
    # Buys a builder
    def buy_builder
      @api.buy_builder
    end

    ##
    # Buys a money
    def buy_money(perc)
      raw_data = @api.buy_currency(Network::CURRENCY_MONEY, perc)
      data = Serializer.parseData(raw_data)

      @player.profile.credits = data.dig(0, 0, 0)
      @player.profile.money = data.dig(0, 0, 1)
    end

    ##
    # Buys a bitcoins
    def buy_bitcoins(perc)
      raw_data = @api.buy_currency(Network::CURRENCY_BITCOINS, perc)
      data = Serializer.parseData(raw_data)

      @player.profile.credits = data.dig(0, 0, 0)
      @player.profile.bitcoins = data.dig(0, 0, 1)
    end

    ##
    # Creates a new account
    def create_player
      raw_data = @api.create_player
      data = Serializer.parseData(raw_data)

      Account.new(
        data.dig(0, 0, 0).to_i,
        data.dig(0, 0, 1),
        data.dig(0, 0, 2)
      )
    end

    ##
    # Gets player info
    def player_info(id)
      raw_data = @api.player_info(id)

      serializer_profile = Serializer::Profile.new(raw_data)
      serializer_profile.parse(0, 0)
    end

    ##
    # Gets detailed player info
    def player_details(id)
      raw_data = @api.player_details(id)
      data = Serializer.parseData(raw_data)

      serializer_profile = Serializer::Profile.new(raw_data)
      profile = serializer_profile.parse(0, 0)
      network = Network::Network.new(@api, @player)
      network.parse(data.dig(1))

      PlayerDetails.new(profile, network)
    end

    ##
    # Generates CP (change platform) code
    def cp_generate_code
      raw_data = @api.cp_generate_code
      data = Serializer.parseData(raw_data)

      data.dig(0, 0, 0)
    end

    ##
    # Uses CP (change platform) code
    def cp_use_code(code, platform)
      raw_data = @api.cp_use_code(code, platform)
      data = Serializer.parseData(raw_data)

      Account.new(
        data.dig(0, 0, 0).to_i,
        data.dig(0, 0, 1)
      )
    end

    ##
    # Checks network connectivity
    def check_connectivity
      @api.check_connectivity
    end

    private

    ##
    # Resolves the optional ssl setting: absence inherits the API default
    # (TLS); explicit booleans are honored; legacy on/off strings are
    # accepted case-insensitively; any other value fails instead of
    # silently downgrading to plaintext.
    def resolve_ssl
      return API::SSL unless @config.key?('ssl')

      case @config['ssl']
      when true, false
        @config['ssl']
      when String
        case @config['ssl'].strip.downcase
        when 'on', 'true' then true
        when 'off', 'false' then false
        else raise ArgumentError, 'Invalid ssl setting (expected true, false, on or off)'
        end
      else
        raise ArgumentError, 'Invalid ssl setting (expected true, false, on or off)'
      end
    end

    ##
    # Returns the configured host or the default game host
    def config_host
      @config.key?('host') ? @config['host'] : API::HOST
    end
  end
end
