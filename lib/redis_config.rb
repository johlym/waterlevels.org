module RedisConfig
  DEFAULT_URL = "redis://127.0.0.1:6379/0".freeze

  module_function

  def url(default: DEFAULT_URL)
    ENV.fetch("REDIS_URL", default)
  end

  # Heroku Key-Value Store (and similar) use self-signed certs on rediss://.
  # VERIFY_NONE is required; ignored for plain redis:// connections.
  def options(default_url: DEFAULT_URL)
    {
      url: url(default: default_url),
      ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
    }
  end
end
