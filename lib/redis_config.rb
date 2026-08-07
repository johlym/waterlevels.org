module RedisConfig
  DEFAULT_URL = "redis://127.0.0.1:6379/0".freeze

  module_function

  def url(default: DEFAULT_URL)
    isolate_test_worker_db(ENV.fetch("REDIS_URL", default))
  end

  # Heroku Key-Value Store (and similar) use self-signed certs on rediss://.
  # VERIFY_NONE is required; ignored for plain redis:// connections.
  def options(default_url: DEFAULT_URL)
    {
      url: url(default: default_url),
      ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
    }
  end

  # Rails parallel test workers share one Redis by default. Pin each worker to
<<<<<<< HEAD
  # its own logical DB so Redis-backed assertions (admin tip refresh, history
  # backfill lock counts, etc.) cannot clobber each other mid-assertion.
=======
  # its own logical DB so process-local job summaries (admin tip refresh, etc.)
  # cannot clobber each other mid-assertion.
>>>>>>> origin/main
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
