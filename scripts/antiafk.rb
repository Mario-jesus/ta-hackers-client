# frozen_string_literal: true

class Antiafk < Sandbox::Script
  MAINTENANCE_INTERVAL = 60
  ONLINE_INTERVAL = 90 * 60
  RETRY_MAX = 180
  TRANSPORT_FAILURES = {
    'SocketError' => 'DNS lookup failed',
    'Net::OpenTimeout' => 'connection timed out',
    'Net::ReadTimeout' => 'response timed out',
    'Net::WriteTimeout' => 'request write timed out',
    'Timeout::Error' => 'request timed out',
    'Errno::ECONNRESET' => 'connection reset',
    'Errno::ECONNREFUSED' => 'connection refused',
    'Errno::ETIMEDOUT' => 'connection timed out',
    'Errno::EHOSTUNREACH' => 'host unreachable',
    'Errno::ENETUNREACH' => 'network unreachable',
    'Errno::EPIPE' => 'connection closed while writing',
    'EOFError' => 'connection closed before the response completed',
    'IOError' => 'connection input/output failed'
  }.freeze

  def main
    return unless configure_timing

    @game.api.client.with_session_cycle do
      log(:info, 'Anti-AFK starting; checking authentication and player load')
      begin
        maintain_session
      rescue Hackers::RequestError => error
        log(:error, "Startup failed during #{@request_stage}: #{failure_reason(error)}; entering exclusive recovery")
        @game.api.client.with_session_pause { |recover| reconnect(recover) }
      end
      log(:info, "Anti-AFK activated successfully; Authenticated session active; next maintenance in #{MAINTENANCE_INTERVAL} seconds; scheduled disconnection after #{@online_interval / 60} minutes")
      online_since = monotonic
      loop do
        sleep([MAINTENANCE_INTERVAL, @online_interval - (monotonic - online_since)].min.clamp(0, MAINTENANCE_INTERVAL))
        if monotonic - online_since >= @online_interval
          scheduled_pause
          online_since = monotonic
        else
          begin
            maintain_session
            log(:info, "Authenticated maintenance succeeded; next maintenance in #{MAINTENANCE_INTERVAL} seconds")
          rescue Hackers::RequestError => error
            log(:error, "Maintenance failed during #{@request_stage}: #{failure_reason(error)}; entering exclusive recovery")
            silenced = false
            @game.api.client.with_session_pause do |recover|
              unless reconnect(recover, deadline: online_since + @online_interval)
                # Keep the same closed gate when recovery reaches the deadline.
                silence_and_reconnect(recover)
                silenced = true
              end
            end
            online_since = monotonic if silenced
          end
        end
      end
    end
  end

  private

  def configure_timing
    usage = 'Usage: script run antiafk [online_minutes] [offline_minutes]'
    if @args.length > 2
      log(:error, "Expected at most two timing arguments. #{usage}")
      return false
    end
    unless @args.all? { |arg| /\A[0-9]+\z/.match?(arg) && arg.to_i.positive? }
      log(:error, "Timing arguments must be positive whole-number minutes. #{usage}")
      return false
    end

    @online_interval = @args[0] ? @args[0].to_i * 60 : ONLINE_INTERVAL
    @offline_interval = @args[1] ? @args[1].to_i * 60 : nil
    true
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Use static diagnostics only: exception text can contain credentials, URLs,
  # server response bodies or terminal control characters.
  def log(level, message)
    @logger.public_send(level, "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S %:z')}] #{message}")
  end

  def failure_reason(error)
    transport = TRANSPORT_FAILURES[error.type]
    return "Network/transport failure: #{transport}" if transport
    return 'TLS connection failed; server rejection unconfirmed' if error.type == 'OpenSSL::SSL::SSLError'
    return 'Server reported a protocol rejection' if error.type == 'Exception'

    status = error.http_status
    if status.is_a?(Integer) && (100..599).cover?(status)
      case status
      when 401 then return 'Server rejected authentication (HTTP 401)'
      when 403 then return 'Server refused the request (HTTP 403)'
      when 429 then return 'Server rate limited the request (HTTP 429)'
      when 500..599 then return "Server returned an error (HTTP #{status})"
      when 400..499 then return "Server rejected the request (HTTP #{status})"
      else return "Unexpected server response (HTTP #{status}); cause unconfirmed"
      end
    end
    return 'Invalid authentication response; cause unconfirmed' if error.type == 'Auth'
    return 'Local tool traffic is paused' if error.type == 'Session'

    'Request failed; cause unconfirmed'
  end

  def maintain_session
    @request_stage = 'authentication'
    @game.auth_minimal
    @request_stage = 'player load'
    @game.player.load
  end

  def scheduled_pause
    log(:info, "Scheduled disconnection: #{@online_interval / 60}-minute cycle ended; blocking new requests and draining in-flight operations")
    @game.api.client.with_session_pause { |recover| silence_and_reconnect(recover) }
  end

  def silence_and_reconnect(recover)
    @game.api.sid = nil
    duration = @offline_interval || rand(240..300)
    log(:info, "Scheduled disconnection: all tool traffic blocked for #{duration} seconds; stopping this job cancels silence")
    deadline = monotonic + duration
    sleep(deadline - monotonic) while monotonic < deadline
    reconnect(recover)
  end

  def reconnect(recover, deadline: nil)
    delay = 10
    loop do
      return false if deadline && monotonic >= deadline

      complete = false
      failure = nil
      begin
        @game.api.sid = nil
        log(:info, 'Reconnection attempt: authenticating and loading player; all other tool traffic blocked')
        recover.call { maintain_session }
        return false if deadline && monotonic >= deadline

        complete = true
        log(:info, 'Reconnection succeeded: authentication and player load complete; tool traffic resumed')
        return true
      rescue Hackers::RequestError => error
        failure = error
      ensure
        @game.api.sid = nil unless complete
      end
      wait = deadline ? [delay, deadline - monotonic].min : delay
      if failure
        seconds = format('%g', [wait, 0].max)
        next_action = if deadline && monotonic + wait >= deadline
                        "scheduled disconnection in #{seconds} seconds"
                      else
                        "retrying in #{seconds} seconds"
                      end
        log(:error, "Reconnection failed during #{@request_stage}: #{failure_reason(failure)}; #{next_action}; all other tool traffic blocked")
      end
      sleep(wait) if wait.positive?
      delay = [delay * 2, RETRY_MAX].min
    end
  end
end
