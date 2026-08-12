# Structured JSON logging for web requests (via Lograge) and ActiveJob lifecycle
# events. Always enabled in every environment.
#
# Shape is tuned for Heroku → Better Stack drains: each line is one JSON object
# with a human `message`, a `level`, an `event`, and flat queryable fields.
# Better Stack nests the parsed line under `message.*` (e.g. `message.job`).
module AppLogging
  PARAM_EXCEPTIONS = %w[controller action format authenticity_token commit].freeze
  USER_AGENT_MAX = 120
  FIELD_ORDER = %i[
    level event message rid job jid queue adapter method path format status
    duration view db queries cached gc allocations controller action location
    ip host cf_ray ua params args error unpermitted_params phase count
  ].freeze
  LOGFMT_TOKEN = /
    (?:^|\s)
    ([A-Za-z_][A-Za-z0-9_]*)=
    (
      "(?:\\.|[^"\\])*"
      |
      \S+
    )
  /x
  STATUS_WORDS = %w[done starting skip skipped ok error].freeze

  module_function

  def enabled?
    true
  end

  def json(data)
    JSON.generate(order_fields(normalize(data)))
  end

  # Prefer this for app events so level/message defaults stay consistent.
  def event(data)
    payload = data.to_h.compact
    payload[:level] ||= "info"
    json(payload)
  end

  def normalize(data)
    data.each_with_object({}) do |(key, value), cleaned|
      next if value.nil?

      cleaned[key] = normalize_value(value)
    end
  end

  def normalize_value(value)
    case value
    when Float
      value.round(2)
    when Hash
      value.transform_values { |item| normalize_value(item) }
    when Array
      value.map { |item| normalize_value(item) }
    else
      value
    end
  end

  # Pull key=value tokens out of legacy SyncProgress / job strings so Better
  # Stack gets flat fields (message.phase, message.updated, …) instead of one
  # opaque msg blob.
  def extract_logfmt(text)
    fields = {}
    text.to_s.scan(LOGFMT_TOKEN) do |key, raw|
      fields[key.to_sym] = coerce_logfmt_value(raw)
    end

    remainder = text.to_s.gsub(LOGFMT_TOKEN, " ")
    status = remainder.split.find { |token| STATUS_WORDS.include?(token) }
    fields[:status] ||= status if status
    fields
  end

  def coerce_logfmt_value(raw)
    value = raw.to_s
    if value.start_with?('"') && value.end_with?('"')
      begin
        return value.undump
      rescue ArgumentError
        value = value[1..-2]
      end
    end

    if value.match?(/\A-?\d+\z/)
      value.to_i
    elsif value.match?(/\A-?\d+\.\d+s\z/)
      value.delete_suffix("s").to_f
    elsif value.match?(/\A-?\d+\.\d+\z/)
      value.to_f
    else
      value
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
      ordered[key.to_s] = data[key] if data.key?(key)
      ordered[key.to_s] = data[key.to_s] if data.key?(key.to_s)
    end
    data.each do |key, value|
      string_key = key.to_s
      ordered[string_key] = value unless ordered.key?(string_key)
    end
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
    # Keep request correlation on every line (including non-Lograge messages).
    # CompactTagFormat merges rid into JSON objects so lines stay valid JSON.
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

  # Merge key=value tags into JSON log lines so TaggedLogging stays JSON-safe.
  module CompactTagFormat
    def format_message(message)
      return message if @tags.empty?

      tag_fields = kv_tag_fields
      return merge_json_tags(tag_fields, message) if tag_fields

      if @tags.size == 1
        "[#{@tags[0]}] #{message}"
      else
        @tags_string ||= "[#{@tags.join("] [")}] "
        "#{@tags_string}#{message}"
      end
    end

    private

    def kv_tag_fields
      fields = {}
      @tags.each do |tag|
        str = tag.to_s
        return nil unless str.include?("=")

        key, value = str.split("=", 2)
        fields[key] = value
      end
      fields
    end

    def merge_json_tags(tag_fields, message)
      msg = message.to_s
      if msg.start_with?("{")
        begin
          data = JSON.parse(msg)
          return JSON.generate(tag_fields.merge(data))
        rescue JSON::ParserError
          # Fall through to wrap as message.
        end
      end

      JSON.generate(tag_fields.merge("message" => msg, "level" => "info"))
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
