source "https://rubygems.org"

ruby "4.0.4"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "jsbundling-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "cssbundling-rails"
gem "jbuilder"
gem "redis", ">= 4.0.1"
gem "sidekiq", "~> 8.0"
gem "sidekiq-scheduler", "~> 6.0"
gem "view_component", "~> 4.0"
gem "faraday", "~> 2.12"
gem "faraday-retry", "~> 2.2"
gem "dotenv-rails"
gem "sentry-ruby"
gem "sentry-rails"
gem "sentry-sidekiq"
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-instrumentation-all"
gem "invisible_captcha"
gem "bento-actionmailer", github: "bentonow/bento-actionmailer", branch: "main"
gem "premailer-rails"
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[windows jruby]

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "factory_bot_rails"
  gem "webmock"
end

group :development do
  gem "web-console"
end

gem "aws-sdk-s3", "~> 1.0"
