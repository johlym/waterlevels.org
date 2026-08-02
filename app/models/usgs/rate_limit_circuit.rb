module Usgs
  # When USGS returns 429, trip this circuit so already-queued jobs stop hammering
  # the hourly request budget instead of retrying into a backlog.
  class RateLimitCircuit
    KEY = "usgs:rate_limit_circuit"

    def self.open!(ttl: nil)
      Rails.cache.write(KEY, true, expires_in: ttl || default_ttl)
    end

    def self.open?
      Rails.cache.exist?(KEY)
    end

    def self.clear!
      Rails.cache.delete(KEY)
    end

    # Stay dark through the rest of the UTC hour (USGS budget window), with a
    # short floor so a trip near :59 still cools down.
    def self.default_ttl
      remaining = (Time.current.utc.end_of_hour - Time.current.utc).to_i + 1
      [ remaining, 5.minutes.to_i ].max.seconds
    end
  end
end
