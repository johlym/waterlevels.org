# Single-line request + job logs. See lib/app_logging.rb.
require Rails.root.join("lib/app_logging")

Rails.application.configure do
  config.lograge.enabled = AppLogging.enabled?

  next unless config.lograge.enabled

  config.lograge.formatter = Lograge::Formatters::KeyValue.new
  config.lograge.base_controller_class = [ "ActionController::Base" ]

  # /up is also silenced by config.silence_healthcheck_path; keep Lograge quiet too.
  config.lograge.ignore_actions = [ "Rails::HealthController#show" ]
  config.lograge.ignore_custom = lambda do |event|
    path = event.payload[:path].to_s
    path == "/up" || path.start_with?("/up?")
  end

  config.lograge.custom_payload do |controller|
    request = controller.request
    {
      ip: request.remote_ip,
      host: request.host,
      ua: AppLogging.truncate_ua(request.user_agent),
      cf_ray: request.headers["CF-Ray"].presence
    }.compact
  end

  config.lograge.custom_options = lambda do |event|
    payload = event.payload
    params = AppLogging.filtered_params(payload[:params])
    options = {
      queries: payload[:queries_count],
      cached: payload[:cached_queries_count],
      gc: event.respond_to?(:gc_time) ? event.gc_time.to_f.round(2) : nil,
      params: params.presence&.then { |p| p.to_json }
    }
    if (error = payload[:exception])
      options[:error] = "#{error[0]}: #{error[1]}"
    end
    options.compact
  end

  config.lograge.before_format = lambda do |data, _payload|
    AppLogging.order_fields(data)
  end
end

AppLogging.install!
