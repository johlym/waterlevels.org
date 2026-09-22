# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = true
  config.enabled_environments = %w[development production staging]

  # Telebugs does not support performance tracing or profiling yet.
  # nil disables tracing completely, including continuation of incoming traces.
  config.traces_sample_rate = nil
  config.profiles_sample_rate = nil

  # Production is the only deployed environment; local uses Rails.env.
  config.environment = Rails.env.production? ? "production" : Rails.env
  # Set by Heroku dyno metadata (labs: runtime-dyno-metadata).
  config.release = ENV["HEROKU_RELEASE_VERSION"] if ENV["HEROKU_RELEASE_VERSION"].present?
  config.debug = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SENTRY_DEBUG", "false"))
end
