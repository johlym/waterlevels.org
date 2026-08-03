class SyncProgress
  def initialize(label, io: $stdout, logger: Rails.logger, every: 100)
    @label = label
    @io = io
    @logger = logger
    @every = every
    @count = 0
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    say("#{label}: starting")
  end

  def step(message)
    say("#{@label}: #{message}")
  end

  def increment(amount = 1)
    @count += amount
    say("#{@label}: #{@count} processed") if (@count % @every).zero?
    @count
  end

  def finish(message = nil)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
    detail = message.presence || "#{@count} processed"
    say("#{@label}: done (#{detail}) in #{format("%.1f", elapsed)}s")
    @count
  end

  private

  def say(message)
    line = "[#{Time.current.strftime("%H:%M:%S")}] #{message}"
    @io&.puts(line)
    @io&.flush
    @logger&.info(message)
  end
end
