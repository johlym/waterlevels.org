require Rails.root.join("lib/redis_config")
require Rails.root.join("lib/app_logging")
require Rails.root.join("lib/app_logging/sidekiq_json_formatter")

Sidekiq.configure_server do |config|
  config.redis = RedisConfig.options
  config.logger.formatter = AppLogging::SidekiqJsonFormatter.new if AppLogging.enabled?

  # Web requests are scanned by the Rack middleware. This covers jobs that run
  # in a Sidekiq process, which are outside that request.
  if Rails.env.development?
    config.server_middleware do |chain|
      require "prosopite/middleware/sidekiq"
      chain.add Prosopite::Middleware::Sidekiq
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = RedisConfig.options
  if AppLogging.enabled? && config.logger.respond_to?(:formatter=)
    config.logger.formatter = AppLogging::SidekiqJsonFormatter.new
  end
end
