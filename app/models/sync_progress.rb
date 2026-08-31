class SyncProgress
  # io defaults to nil: Rails.logger already goes to stdout on Heroku, and
  # AppLogging always emits a JSON line. Passing $stdout (or a StringIO in
  # tests) is only for a local human stream that is not also drained.
  def initialize(label, io: nil, logger: Rails.logger, every: 100)
    @label = label
    @io = io
    @logger = logger
    @every = every
    @count = 0
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    say("starting", status: "starting")
  end

  def step(message = nil, **fields)
    if message.is_a?(Hash)
      fields = message.merge(fields)
      message = fields.delete(:message)
    end
    say(message, **fields)
  end

  def increment(amount = 1)
    @count += amount
    say("#{@count} processed", count: @count, status: "running") if (@count % @every).zero?
    @count
  end

  def finish(message = nil, **fields)
    if message.is_a?(Hash)
      fields = message.merge(fields)
      message = fields.delete(:message)
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at

    if message.present? && !fields.key?(:detail)
      if message.to_s.include?("=")
        fields = AppLogging.extract_logfmt(message).merge(fields)
      else
        fields = { detail: message }.merge(fields)
      end
      message = "done"
    end

    say(
      message || "done",
      status: fields[:status] || "done",
      detail: fields[:detail] || "#{@count} processed",
      elapsed: fields[:elapsed] || elapsed.round(1),
      count: fields[:count] || @count,
      **fields.except(:status, :detail, :elapsed, :count)
    )
    @count
  end

  private

  def say(message = nil, **fields)
    human = human_line(message, fields)
    @io&.puts("[#{Time.current.strftime("%H:%M:%S")}] #{@label}: #{human}")
    @io&.flush

    @logger&.info(logger_line(message, fields, human))
  end

  def human_line(message, fields)
    return message.to_s if message.present? && fields.blank?

    parts = []
    parts << message if message.present?
    fields.each do |key, value|
      next if value.nil?
      next if message.present? && message.to_s.include?("#{key}=")
      next if key.to_sym == :status && message.to_s == value.to_s

      parts << "#{key}=#{format_human_value(value)}"
    end
    parts.join(" ").presence || "progress"
  end

  def format_human_value(value)
    case value
    when Float
      format("%.1f", value)
    when String
      if value.match?(%r{[\s"=]})
        value.dump
      else
        value
      end
    else
      value
    end
  end

  def logger_line(message, fields, human)
    if defined?(AppLogging) && AppLogging.enabled?
      extracted = message.present? ? AppLogging.extract_logfmt(message) : {}
      payload = extracted.merge(fields.compact)
      AppLogging.event(
        event: "sync.progress",
        job: @label,
        message: summary_message(message, payload, human),
        **payload
      )
    else
      "#{@label}: #{human}"
    end
  end

  def summary_message(message, payload, human)
    if payload[:phase]
      [ @label, payload[:phase], payload[:status] ].compact.join(" ")
    elsif message.present? && !message.to_s.include?("=")
      "#{@label}: #{message}"
    else
      "#{@label}: #{human}"
    end
  end
end
