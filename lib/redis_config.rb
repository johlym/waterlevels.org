module RedisConfig
  DEFAULT_URL = "redis://127.0.0.1:6379/0".freeze

  module_function

  def url(default: DEFAULT_URL)
    isolate_test_worker_db(ENV.fetch("REDIS_URL", default))
  end

  # Redis Cloud presents a public CA (download redis_ca.pem from the console;
  # the OS trust store is usually enough). VERIFY_PEER is the default.
  # Set REDIS_SSL_VERIFY=none only for leftover self-signed rediss:// hosts
  # (e.g. some Heroku Key-Value Store plans). Ignored for redis://.
  def options(default_url: DEFAULT_URL)
    {
      url: url(default: default_url),
      ssl_params: { verify_mode: ssl_verify_mode }
    }
  end

  def cache_options
    cache_url = ENV["REDIS_CACHE_URL"].to_s.strip
    return options(default_url: cache_url) if cache_url.present?

    options
  end

  def ssl_verify_mode
    if %w[none 0 false off].include?(ENV["REDIS_SSL_VERIFY"].to_s.strip.downcase)
      OpenSSL::SSL::VERIFY_NONE
    else
      OpenSSL::SSL::VERIFY_PEER
    end
  end

  # Rails parallel test workers share one Redis by default. Pin each worker to
  # its own logical DB so Redis-backed assertions (admin tip refresh, history
  # backfill lock counts, etc.) cannot clobber each other mid-assertion.
  def isolate_test_worker_db(configured)
    return configured unless defined?(Rails) && Rails.env.test?
    return configured unless defined?(ActiveSupport::TestCase)

    worker = ActiveSupport::TestCase.parallel_worker_id
    return configured if worker.nil?

    uri = URI.parse(configured)
    uri.path = "/#{worker.to_i}"
    uri.to_s
  rescue URI::InvalidURIError
    configured
  end
end
