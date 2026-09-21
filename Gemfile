source "https://rubygems.org"

ruby File.read(".ruby-version").strip

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# json 3.0 (Ruby 4.0.7 default) made JSON.parse keywords-only.
# ActiveSupport 8.1 still calls JSON.parse(json, options), which
# cannot dump jsonb tables and then breaks db:test:prepare.
gem "json", "~> 3.0"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "jsbundling-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "cssbundling-rails"
gem "jbuilder"
gem "redis", ">= 4.0.1"
gem "sidekiq", "~> 8.1"
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

group :development, :test do
  gem "debug", platforms: %i[mri], require: "debug/prelude"
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
gem "lograge", "~> 0.14"

gem "meta-tags", ">= 2.1"
