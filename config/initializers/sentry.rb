# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = true
  config.enabled_environments = %w[development production staging]

  # Full sampling in non-production; keep production volume reasonable.
  config.traces_sample_rate = Rails.env.production? ? 0.1 : 1.0

  # Production is the only deployed environment; local uses Rails.env.
  config.environment = Rails.env.production? ? "production" : Rails.env
  # Set by Heroku dyno metadata (labs: runtime-dyno-metadata).
  config.release = ENV["HEROKU_RELEASE_VERSION"] if ENV["HEROKU_RELEASE_VERSION"].present?
  config.debug = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SENTRY_DEBUG", "false"))
end
