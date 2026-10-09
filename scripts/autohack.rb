# frozen_string_literal: true

require 'optparse'
require 'set'

class Autohack < Sandbox::Script
  # Draft-sourced constant: these target ids are never attempted.
  TARGET_ID_SKIP = [127]

  # User-resolved options (odd/tasks/autohack-functional-repair.md):
  # loot percent defaults to 5; percents are integer 0..100 (100 allowed);
  # between-target timing defaults to the conservative upstream interval.
  COFFERS_DEFAULT = 5
  COFFERS_FIRST = 0
  COFFERS_LAST = 100

  TIMING_CONSERVATIVE = 420..950
  TIMING_FAST = 15..25
  TIMING_CUSTOM = /\A(\d+)\.\.(\d+)\z/

  # Upstream-fixed per-action intervals (draft and 9802b81 precedent).
  SLEEP_AFTER_NET = 4..9
  SLEEP_AFTER_UPDATE = 35..95
  SLEEP_AFTER_FIGHT = 5..12

  # Final-fight success bits kept from the draft constants (1|2|4). The
  # logged result is raw server output, never a guaranteed victory.
  SUCCESS_BITS = Hackers::Network::SUCCESS_CORE |
                 Hackers::Network::SUCCESS_RESOURCES |
                 Hackers::Network::SUCCESS_CONTROL

  USAGE = 'usage: run autohack [--coffers 0..100] [--timing conservative|fast|MIN..MAX] <count>'

  # App-settings versions for the replay string use the legacy draft key
  # strings. The current backend key names are unverified offline, so they
  # are only read and validated at runtime, never guessed as server truth.
  VERSION_NODE_SETTINGS_KEY = 'node types'
  VERSION_PROGRAM_SETTINGS_KEY = 'program types'

  ##
  # Stops the whole run (cancellation, an ambiguous mutation outcome or an
  # operational bound reached). Messages are static English sentences; they
  # never carry exception bodies or server payloads.
  class StopRun < StandardError; end

  def initialize(game, shell, logger, args)
    super

    @mutex = Mutex.new
    @stop_requested = false
    @open_target = nil
    @attempted = Set.new
    @completed_total = 0
  end

  ##
  # Runner-side cancellation hook. It is invoked by the job runner before
  # Thread.kill and after a normal main, so it must stay idempotent. It
  # only flips tiny flags under a mutex and performs no IO itself; the
  # leave request for a confirmed entry runs in the script thread's ensure.
  def finish
    @mutex.synchronize { @stop_requested = true }
  end

  def main
    return if stop_requested?

    options = parse_options
    return unless options

    api = @game.api
    return unless preflight(api)

    begin
      run_battles(options, api)
    rescue StopRun => e
      @logger.log("Stopping: #{e.message}")
    ensure
      close_open_target(api)
      @logger.log("Run finished: #{@completed_total} successful attacks")
    end
  end

  private

  ##
  # Parses raw argument tokens (OptionParser over the sandbox args). Any
  # invalid option, value, timing or count prints actionable usage and
  # returns nil before any server call happens.
  def parse_options
    tokens = Array(@args).dup

    if tokens.delete('--help') || tokens.delete('-h')
      @logger.log(USAGE)
      return nil
    end

    options = { coffers: COFFERS_DEFAULT, timing: TIMING_CONSERVATIVE }

    parser = OptionParser.new do |opts|
      opts.on('--coffers PERCENT') do |value|
        valid, percent = parse_coffers(value)
        return usage('coffers must be an integer 0..100') unless valid

        options[:coffers] = percent
      end

      opts.on('--timing TIMING') do |value|
        valid, seconds = parse_timing(value)
        return usage('timing must be conservative, fast or MIN..MAX with a positive minimum') unless valid

        options[:timing] = seconds
      end
    end

    begin
      parser.parse!(tokens)
    rescue OptionParser::ParseError
      return usage('invalid or unexpected option')
    end

    return usage('a running count is required') if tokens.length != 1
    return usage('count must be a positive integer') unless tokens.first.match?(/\A\d+\z/) && !tokens.first.to_i.zero?

    options[:count] = tokens.first.to_i
    options
  end

  def parse_coffers(value)
    percent = Integer(value, 10)
    [(COFFERS_FIRST..COFFERS_LAST).cover?(percent), percent]
  rescue ArgumentError, TypeError
    [false, nil]
  end

  def parse_timing(value)
    return [true, TIMING_CONSERVATIVE] if value == 'conservative'
    return [true, TIMING_FAST] if value == 'fast'

    match = TIMING_CUSTOM.match(value.to_s)
    return [false, nil] unless match

    minimum, maximum = match.captures.map { |token| token.to_i }
    return [false, nil] unless minimum.positive? && minimum <= maximum

    [true, minimum..maximum]
  end

  def usage(reason)
    @logger.log("Invalid arguments: #{reason}")
    @logger.log(USAGE)
    nil
  end

  ##
  # Verifies prerequisites before any battle call: the session, the
  # configured instance version (a blank version is never sent), the own
  # player with a country, the app-settings version keys and the world.
  # All datasets use their existing public loaded?/load methods and load
  # only happens here, in preflight.
  def preflight(api)
    unless @game.connected?
      @logger.log(NOT_CONNECTED)
      return false
    end

    if api.version.to_s.empty?
      @logger.log('API version is not configured; refusing to send a blank version')
      return false
    end

    begin
      @game.player.load
    rescue StandardError => e
      @logger.log("Own player unavailable: #{e.class}")
      return false
    end

    profile = @game.player.profile
    if profile.nil? || profile.country.to_s.strip.empty?
      @logger.log('Own player has no country; refusing to load the world')
      return false
    end

    settings = @game.app_settings
    begin
      settings.load unless settings.loaded?
    rescue StandardError => e
      @logger.log("App settings unavailable: #{e.class}")
      return false
    end

    missing = [VERSION_NODE_SETTINGS_KEY, VERSION_PROGRAM_SETTINGS_KEY].select do |key|
      settings.get(key).to_s.strip.empty?
    end
    unless missing.empty?
      @logger.log("Missing app settings keys: #{missing.join(', ')}; no battles started")
      return false
    end

    begin
      @game.world.load
    rescue StandardError => e
      @logger.log("World unavailable: #{e.class}")
      return false
    end

    if @game.world.targets.nil?
      @logger.log('World targets unavailable; no battles started')
      return false
    end

    true
  end

  ##
  # The battle loop. Each target id is attempted at most once per run,
  # blacklisted ids are skipped, mutations are never retried, any
  # uncertain attack outcome stops the run immediately (no next target,
  # no blind leave), and at most one bounded refresh happens when a page
  # has no actionable target.
  def run_battles(options, api)
    targets = @game.world.targets
    refreshed_once = false

    until stop_requested?
      any_actionable = false

      targets.each do |target|
        break if completed?(options[:count])

        next if TARGET_ID_SKIP.include?(target.id) || @attempted.include?(target.id)

        raise StopRun, 'Stop requested before the next target' if stop_requested?

        @attempted.add(target.id)
        any_actionable = true

        begin
          attempt_target(target, api, options)
          @completed_total += 1
        rescue StopRun
          raise
        end

        break if completed?(options[:count])
        sleep(rand(options[:timing]))
      end

      break if completed?(options[:count])
      next if any_actionable

      if refreshed_once
        raise StopRun, 'No actionable targets after one refresh'
      end

      refreshed_once = true
      begin
        targets.new
      rescue StandardError => e
        @logger.log("New targets refresh failed: #{e.class}")
        raise StopRun, 'New targets refresh failed'
      end
    end
  end

  def completed?(count)
    @completed_total >= count
  end

  ##
  # One full battle sequence for one target. Every mutation stage is sent
  # exactly once; a network failure at a non-idempotent stage stops the
  # run instead of retrying. The entry becomes known right after the
  # validated attack response, and that known entry is closed by this
  # thread's ensure through close_open_target, exactly once.
  def attempt_target(target, api, options)
    net = attack_stage(target, api)

    record_open_target(target.id)

    stop_gate('Stop requested after the attack network; leaving network')

    sleep(rand(SLEEP_AFTER_NET))

    begin
      api.update_fight(
        target.id,
        {
          money: 0, bitcoin: 0, nodes: '', loots: '',
          success: Hackers::Network::SUCCESS_FAIL, programs: ''
        }
      )
    rescue StandardError => e
      @logger.log("Fight update failed: #{e.class}")
      raise StopRun, 'Fight update failed; leaving the known entry'
    end

    sleep(rand(SLEEP_AFTER_UPDATE))

    stop_gate('Stop requested before the fight finish; leaving network')

    begin
      api.finish_fight(target.id, finish_payload(net, api, options))
      @logger.log('Legacy server fight result is raw and not verified')
    rescue StandardError => e
      @logger.log("Fight finish failed: #{e.class}")
      raise StopRun, 'Fight finish failed; leaving network'
    end

    sleep(rand(SLEEP_AFTER_FIGHT))

    release_open_target
    begin
      api.leave_net(target.id)
    rescue StandardError => e
      @logger.log("Fight cleanup failed: #{e.class}")
      raise StopRun, 'Fight cleanup (leave) failed; stopping'
    end

    begin
      @game.player.load
    rescue StandardError => e
      @logger.log("Own player refresh failed: #{e.class}")
    end
  end

  ##
  # The attack stage. Any transport or parser failure here is an UNCERTAIN
  # entry outcome: the backend may already have recorded an entry even
  # though the response was lost or unparsable, so the run stops with no
  # next target and no blind leave, and logs an actionable manual
  # inspection requirement (class-only, never a raw error body). The API
  # contract rejects invalid currencies with ParserError before any
  # percentage math.
  def attack_stage(target, api)
    begin
      net = api.attack_net(target.id)
    rescue StandardError => e
      @logger.log("Attack request failed: #{e.class}")
      @logger.log('Attack outcome is uncertain; run stopped; manual inspection is required')
      raise StopRun, 'Attack outcome uncertain; no further targets'
    end

    unless net.is_a?(Hash) && net.key?('profile') && !net['profile'].nil?
      @logger.log('Attack response has no usable profile')
      @logger.log('Attack outcome is uncertain; run stopped; manual inspection is required')
      raise StopRun, 'Attack outcome uncertain; no further targets'
    end

    net
  end

  ##
  # Final payload: integer floor percentage of the validated raw profile
  # coffers, computed per currency with no compounding.
  def finish_payload(net, api, options)
    profile = net.fetch('profile')

    {
      money: loot_amount(profile.money, options[:coffers]),
      bitcoin: loot_amount(profile.bitcoins, options[:coffers]),
      nodes: '',
      loots: '',
      success: SUCCESS_BITS,
      programs: '',
      summary: '',
      version: version_string(api),
      replay: ''
    }
  end

  def loot_amount(amount, percent)
    amount * percent / 100
  end

  def version_string(api)
    [
      api.version.to_s,
      @game.app_settings.get(VERSION_NODE_SETTINGS_KEY).to_s,
      @game.app_settings.get(VERSION_PROGRAM_SETTINGS_KEY).to_s
    ].join(',')
  end

  def stop_gate(message)
    raise StopRun, message if stop_requested?
  end

  def stop_requested?
    @mutex.synchronize { @stop_requested }
  end

  def record_open_target(target)
    @mutex.synchronize { @open_target = target }
  end

  def open_target
    @mutex.synchronize { @open_target }
  end

  def release_open_target
    @mutex.synchronize { @open_target = nil }
  end

  ##
  # Owner-side cleanup for confirmed battle entries: fires at most once,
  # in the script thread, through main's ensure (normal completion and
  # Thread.kill both land here). The runner's finish hook never performs
  # IO, so there is never a concurrent or second leave request.
  def close_open_target(api)
    target = open_target
    return if target.nil?

    release_open_target

    begin
      api.leave_net(target)
    rescue StandardError => e
      @logger.log("Confirmed-entry cleanup failed: #{e.class}")
    end
  end
end
