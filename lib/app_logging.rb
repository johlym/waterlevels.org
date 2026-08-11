# Structured, Heroku-router-style logging for web requests (via Lograge) and
# ActiveJob lifecycle events. Enabled in production by default; set LOGRAGE=1
# to enable in development/test, or LOGRAGE=0 to disable in production.
module AppLogging
  PARAM_EXCEPTIONS = %w[controller action format authenticity_token commit].freeze
  USER_AGENT_MAX = 120
  FIELD_ORDER = %i[
    method path format status duration view db queries cached gc allocations
    controller action location ip host cf_ray ua params error unpermitted_params
  ].freeze

  module_function

  def enabled?
    return false if ENV["LOGRAGE"] == "0"
    return true if ENV["LOGRAGE"] == "1"

    Rails.env.production?
  end

  def key_value(data)
    data.each_with_object([]) do |(key, value), parts|
      next if value.nil?

      parts << "#{key}=#{format_value(key, value)}"
    end.join(" ")
  end

  def format_value(key, value)
    case value
    when Float
      format("%.2f", value)
    when Hash, Array
      value.to_json
    else
      text = value.to_s
      if key.to_sym == :error || text.match?(/[\s"'=]/)
        text.dump
      else
        text
      end
    end
  end

  def filtered_params(params)
    return {} if params.blank?

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filter.filter(params).except(*PARAM_EXCEPTIONS)
  rescue StandardError
    {}
  end

  def truncate_ua(user_agent)
    return if user_agent.blank?

    ua = user_agent.to_s
    return ua if ua.length <= USER_AGENT_MAX

    "#{ua[0, USER_AGENT_MAX - 1]}…"
  end

  def order_fields(data)
    ordered = {}
    FIELD_ORDER.each do |key|
      ordered[key] = data[key] if data.key?(key)
    end
    data.each { |key, value| ordered[key] = value unless ordered.key?(key) }
    ordered
  end

  def install!
    return if @installed
    return unless enabled?

    @installed = true
    install_compact_tag_format!
    install_request_id_tag!
    install_active_job_logging!
  end

  def install_compact_tag_format!
    ActiveSupport::TaggedLogging::TagStack.prepend(CompactTagFormat)
  end

  def install_request_id_tag!
    # Keep request correlation on every line (including non-Lograge messages)
    # but as rid=… so it matches the key=value style.
    Rails.application.config.log_tags = [ ->(request) { "rid=#{request.request_id}" } ]
  end

  def install_active_job_logging!
    # ActiveJob::Base (and its LogSubscriber) may not be loaded yet during
    # early initializers in production — wait for the load hook.
    ActiveSupport.on_load(:active_job) do
      prepend AppLogging::QuietActiveJobTags
      self.logger = Rails.logger if Rails.logger

      require Rails.root.join("lib/app_logging/job_log_subscriber")
      ActiveJob::LogSubscriber.detach_from(:active_job)
      AppLogging::JobLogSubscriber.attach_to :active_job
    end
  end

  # When every tag is already key=value, join with spaces instead of [brackets].
  module CompactTagFormat
    def format_message(message)
      return message if @tags.empty?
      return "#{@tags.join(" ")} #{message}" if @tags.all? { |tag| tag.to_s.include?("=") }

      if @tags.size == 1
        "[#{@tags[0]}] #{message}"
      else
        @tags_string ||= "[#{@tags.join("] [")}] "
        "#{@tags_string}#{message}"
      end
    end
  end

  # ActiveJob wraps every perform/enqueue in [ActiveJob] [JobClass] [job_id]
  # tags. Those duplicate the class/id already present in job messages and in
  # our structured lifecycle lines — silence them when AppLogging is on.
  module QuietActiveJobTags
    private

    def tag_logger(*_tags)
      yield
    end
  end
end
