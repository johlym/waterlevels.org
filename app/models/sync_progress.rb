class SyncProgress
  def initialize(label, io: $stdout, logger: Rails.logger, every: 100)
    @label = label
    @io = io
    @logger = logger
    @every = every
    @count = 0
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    say("starting")
  end

  def step(message)
    say(message)
  end

  def increment(amount = 1)
    @count += amount
    say("#{@count} processed") if (@count % @every).zero?
    @count
  end

  def finish(message = nil)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
    detail = message.presence || "#{@count} processed"
    say("done detail=#{detail.to_s.dump} elapsed=#{format("%.1f", elapsed)}s")
    @count
  end

  private

  def say(message)
    # Human rake/console stream keeps the classic labeled lines.
    @io&.puts("[#{Time.current.strftime("%H:%M:%S")}] #{@label}: #{message}")
    @io&.flush

    # Logger lines are JSON when AppLogging is on, and avoid repeating the job
    # class when structured job lifecycle events are already emitted.
    @logger&.info(logger_line(message))
  end

  def logger_line(message)
    if defined?(AppLogging) && AppLogging.enabled?
      AppLogging.json(job: @label, msg: message)
    else
      "#{@label}: #{message}"
    end
  end
end
