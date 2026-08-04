# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = true
  config.enabled_environments = %w[development production staging]

  # Full sampling in non-production; keep production volume reasonable.
  config.traces_sample_rate = Rails.env.production? ? 0.1 : 1.0

  config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
  config.release = ENV["SENTRY_RELEASE"] if ENV["SENTRY_RELEASE"].present?
end
