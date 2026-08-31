module Nldi
  # Navigation is capped (~400 req/hr per client). A 429 trips this through
  # the rest of the UTC hour so rake/jobs stop hammering NLDI.
  class RateLimitCircuit
    CACHE_KEY = "nldi:rate_limit_circuit".freeze

    def self.open!(ttl: nil)
      Rails.cache.write(CACHE_KEY, true, expires_in: ttl || default_ttl)
    end

    def self.open?
      Rails.cache.exist?(CACHE_KEY)
    end

    def self.clear!
      Rails.cache.delete(CACHE_KEY)
    end

    def self.default_ttl
      remaining = (Time.current.utc.end_of_hour - Time.current.utc).to_i + 1
      [ remaining, 5.minutes.to_i ].max.seconds
    end
  end
end
