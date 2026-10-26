# frozen_string_literal: true

class Antiafk < Sandbox::Script
  MAINTENANCE_INTERVAL = 60
  ONLINE_INTERVAL = 3 * 60 * 60
  RETRY_MAX = 180

  def main
    @game.api.client.with_session_cycle do
      begin
        maintain_session
      rescue Hackers::RequestError
        @game.api.client.with_session_pause { |recover| reconnect(recover) }
      end
      online_since = monotonic
      loop do
        sleep([MAINTENANCE_INTERVAL, ONLINE_INTERVAL - (monotonic - online_since)].min.clamp(0, MAINTENANCE_INTERVAL))
        if monotonic - online_since >= ONLINE_INTERVAL
          scheduled_pause
          online_since = monotonic
        else
          begin
            maintain_session
          rescue Hackers::RequestError
            @logger.error('Authenticated maintenance failed; recovering exclusively')
            silenced = false
            @game.api.client.with_session_pause do |recover|
              unless reconnect(recover, deadline: online_since + ONLINE_INTERVAL)
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

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def maintain_session
    @game.auth_minimal
    @game.player.load
  end

  def scheduled_pause
    @logger.info('Draining tool traffic for scheduled silence')
    @game.api.client.with_session_pause { |recover| silence_and_reconnect(recover) }
  end

  def silence_and_reconnect(recover)
    @game.api.sid = nil
    duration = rand(240..300)
    @logger.info("Tool traffic silent for #{duration} seconds; stopping this job cancels silence")
    deadline = monotonic + duration
    sleep(deadline - monotonic) while monotonic < deadline
    reconnect(recover)
  end

  def reconnect(recover, deadline: nil)
    delay = 10
    loop do
      return false if deadline && monotonic >= deadline

      complete = false
      begin
        @game.api.sid = nil
        @logger.info('Reconnecting exclusively')
        recover.call { maintain_session }
        return false if deadline && monotonic >= deadline

        complete = true
        @logger.info('Authenticated player loaded; tool traffic resumed')
        return true
      rescue Hackers::RequestError
        @logger.error("Reconnection failed; retrying in #{delay} seconds")
      ensure
        @game.api.sid = nil unless complete
      end
      wait = deadline ? [delay, deadline - monotonic].min : delay
      sleep(wait) if wait.positive?
      delay = [delay * 2, RETRY_MAX].min
    end
  end
end
