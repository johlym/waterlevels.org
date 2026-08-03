require Rails.root.join("lib/redis_config")

Sidekiq.configure_server do |config|
  config.redis = RedisConfig.options
end

Sidekiq.configure_client do |config|
  config.redis = RedisConfig.options
end
