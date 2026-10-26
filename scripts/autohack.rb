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

  USAGE = 'usage: run autohack [--coffers 0..100] [--timing conservative|fast|MIN..MAX] [--count N] [<count>]'

  # Attack count policy (odd/tasks/autohack-functional-repair.md T4): with
  # no arguments the default is one attack, --count N is the explicit form
  # and the legacy bare positional count stays accepted with a loud
  # warning. There is intentionally no ID detection and no magnitude cap:
  # every accepted value is a count, however large.
  COUNT_DEFAULT = 1

  LEGACY_COUNT_WARNING =
    'Legacy positional argument is an attack count, not a player/network ID; prefer --count N'

  # Typed diagnostic stage codes; stage identifiers are constant words.
  STAGE_ATTACK = 'attack'
  STAGE_UPDATE = 'update'
  STAGE_FINISH = 'finish'
  STAGE_LEAVE = 'leave'

  # Static summary words; they carry no promise about server outcomes.
  SUMMARY_COMPLETED = 'completed'
  SUMMARY_STOPPED = 'stopped'
  SUMMARY_CANCELLED = 'cancelled'

  # Honest labels when no known safe value exists.
  STATUS_UNKNOWN = 'status unknown'
  TYPE_UNKNOWN = 'unknown'

  # Closure wording is deliberately not 'closed': a completed leave request
  # (even a raw accepted response) is not proof of server-side closure.
  CLOSURE_LEAVE_COMPLETED = 'leave request completed; server closure unverified'
  CLOSURE_NOT_CONFIRMED = 'entry closure not confirmed'
  CLOSURE_NO_ENTRY = 'no confirmed entry'

  # Allowlist of error types this codebase constructs deterministically
  # (the 'Exception' envelope type plus the mapped game exceptions in
  # lib/hackers/exceptions.rb, and the client's own 'HTTP' wrapper error).
  # Server types may be arbitrary strings, so the final summary echoes a
  # type only when it is allowlisted and prints the literal 'unknown'
  # otherwise; no message, description or body token is ever echoed.
  TYPED_ERROR_TYPES = ([Hackers::EXCEPTION_TYPE] + Hackers::EXCEPTIONS.keys + ['HTTP']).freeze

  ##
  # One typed failure record: stage code, safe HTTP status label and an
  # allowlisted type label. Never carries a description, body or URL.
  StageFailure = Struct.new(:stage, :status, :type)

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
    @attempted_total = 0
    @entry_confirmed = false
    @leave_request_completed = false
    @primary_failure = nil
    @cleanup_failure = nil
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

    announce_selection_plan(options)

    api = @game.api
    return unless preflight(api)

    begin
      run_battles(options, api)
    rescue StopRun => e
      @logger.log("Stopping: #{e.message}")
    ensure
      close_open_target(api)
      log_final_summary(options)
    end
  end

  private

  ##
  # Parses raw argument tokens (OptionParser over the sandbox args). Any
  # invalid option, value, timing or count prints actionable usage and
  # returns nil before any server call happens.
  #
  # Count resolution: --count N wins; then at most one legacy positional
  # integer (accepted with the loud legacy warning); then the default of
  # one. A positional token together with --count, duplicate --count
  # options (even with identical values), more than one positional token,
  # or a non-positive or non-numeric count value is rejected with usage
  # before any call. Huge digit runs are still counts - there is no ID
  # detection or magnitude cap, because the legacy form was kept by user
  # decision.
  def parse_options
    tokens = Array(@args).dup

    if tokens.delete('--help') || tokens.delete('-h')
      @logger.log(USAGE)
      return nil
    end

    options = { coffers: COFFERS_DEFAULT, timing: TIMING_CONSERVATIVE, count: COUNT_DEFAULT }
    count_given = false

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

      opts.on('--count COUNT') do |value|
        return usage('count given more than once') if count_given

        valid, count = parse_count(value)
        return usage('count must be a positive integer') unless valid

        count_given = true
        options[:count] = count
      end
    end

    begin
      parser.parse!(tokens)
    rescue OptionParser::ParseError
      return usage('invalid, unexpected or incomplete option')
    end

    return usage('pass either --count N or one legacy positional count, not both') if count_given && !tokens.empty?
    return usage('only one bare positional count is accepted') if tokens.length > 1

    legacy_positional = false
    unless tokens.empty?
      valid, count = parse_count(tokens.first)
      return usage('count must be a positive integer') unless valid

      legacy_positional = true
      options[:count] = count
    end

    @logger.log(LEGACY_COUNT_WARNING) if legacy_positional

    options
  end

  ##
  # Positive decimal digits only, no magnitude cap and no ID guesses: any
  # accepted value is an attack count, exactly as typed.
  def parse_count(value)
    text = value.to_s
    return [false, nil] unless text.match?(/\A\d+\z/)

    count = text.to_i
    [count.positive?, count]
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
  # One human-readable plan line before any battle call. Safe constants
  # only: requested count, coffers percentage and timing interval. No IDs
  # are asked for anywhere in this script; the world's offered targets are
  # selected automatically (id 127 is skipped).
  def announce_selection_plan(options)
    @logger.log(
      "Automatic target selection; requested attacks #{options[:count]}; " \
      "coffers #{options[:coffers]}; timing #{options[:timing].first}..#{options[:timing].last}; " \
      'no IDs accepted'
    )
  end

  ##
  # Final run summary, written once after all cleanup, in the same ensure
  # that runs for normal completion and Thread.kill. It distinguishes a
  # completed run, a cancelled run and a stopped run; reports local request
  # counters with the explicit note that server outcomes are unverified;
  # keeps the primary failure and the cleanup failure as separate records;
  # and claims a closed known entry only when a leave request actually
  # confirmed it. There is no 'successful attacks' claim anywhere.
  def log_final_summary(options)
    lines = [
      "Run #{summary_status(options)}: #{@completed_total} completed request sequences (of #{@attempted_total} attempted)"
    ]
    lines << 'server outcomes unverified'
    lines << "primary failure: stage=#{@primary_failure.stage}, #{@primary_failure.status}, type=#{@primary_failure.type}" if @primary_failure
    lines << "cleanup failure: stage=#{@cleanup_failure.stage}, #{@cleanup_failure.status}, type=#{@cleanup_failure.type}" if @cleanup_failure
    lines << entry_closure_line

    @logger.log(lines.join('; '))
  end

  ##
  # StopRun messages stay static local sentences (never private bodies or
  # exception text), so the summary word only distinguishes completion,
  # cancellation and a stop.
  def summary_status(options)
    if @primary_failure.nil? && @cleanup_failure.nil? && completed?(options[:count])
      SUMMARY_COMPLETED
    elsif stop_requested?
      SUMMARY_CANCELLED
    else
      SUMMARY_STOPPED
    end
  end

  ##
  # A closed known entry is claimed only when a leave request was accepted
  # without an exception; uncertainty is stated, never papered over. Per
  # verifier finding F2, even a completed raw leave response is NOT an
  # authoritative server closure, so the wording stays descriptive.
  def entry_closure_line
    return CLOSURE_LEAVE_COMPLETED if @leave_request_completed
    return CLOSURE_NOT_CONFIRMED if @entry_confirmed

    CLOSURE_NO_ENTRY
  end

  def record_primary_failure(stage, error = nil)
    @primary_failure = typed_failure(stage, error)
  end

  def record_cleanup_failure(stage, error = nil)
    @cleanup_failure = typed_failure(stage, error)
  end

  def typed_failure(stage, error)
    return StageFailure.new(stage, STATUS_UNKNOWN, TYPE_UNKNOWN) if error.nil?

    StageFailure.new(stage, status_label(error), type_label(error))
  end

  ##
  # Safe status evidence: an actual HTTP status only when the exception
  # carries an integer in the 100..599 range.
  def status_label(error)
    status = error.http_status if error.respond_to?(:http_status)
    return "HTTP #{status}" if status.is_a?(Integer) && status.between?(100, 599)

    STATUS_UNKNOWN
  end

  ##
  # Safe type evidence: only allowlisted, deterministically constructed
  # types are echoed; an absent value or an arbitrary server/transport
  # string prints the literal "unknown" instead.
  def type_label(error)
    type = error.type if error.respond_to?(:type)
    type = type.to_s.strip
    return TYPE_UNKNOWN unless TYPED_ERROR_TYPES.include?(type)

    type
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
    @attempted_total += 1
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
      record_primary_failure(STAGE_UPDATE, e)
      raise StopRun, 'Fight update failed; leaving the known entry'
    end

    sleep(rand(SLEEP_AFTER_UPDATE))

    stop_gate('Stop requested before the fight finish; leaving network')

    begin
      api.finish_fight(target.id, finish_payload(net, api, options))
      @logger.log('Legacy server fight result is raw and not verified')
    rescue StandardError => e
      @logger.log("Fight finish failed: #{e.class}")
      record_primary_failure(STAGE_FINISH, e)
      raise StopRun, 'Fight finish failed; leaving network'
    end

    sleep(rand(SLEEP_AFTER_FIGHT))

    release_open_target
    begin
      api.leave_net(target.id)
      @leave_request_completed = true
    rescue StandardError => e
      @logger.log("Fight cleanup failed: #{e.class}")
      record_primary_failure(STAGE_LEAVE, e)
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
      record_primary_failure(STAGE_ATTACK, e)
      @logger.log('Attack outcome is uncertain; run stopped; manual inspection is required')
      raise StopRun, 'Attack outcome uncertain; no further targets'
    end

    unless net.is_a?(Hash) && net.key?('profile') && !net['profile'].nil?
      @logger.log('Attack response has no usable profile')
      record_primary_failure(STAGE_ATTACK)
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
    @mutex.synchronize do
      @open_target = target
      @entry_confirmed = true
      # Per-entry reset (verifier finding F1): a leave completion from an
      # earlier, long-closed target must never be reported for a NEWLY
      # confirmed entry. Pure field writes; no IO is held under the mutex.
      @leave_request_completed = false
    end
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
      @leave_request_completed = true
    rescue StandardError => e
      @logger.log("Confirmed-entry cleanup failed: #{e.class}")
      record_cleanup_failure(STAGE_LEAVE, e)
    end
  end
end
