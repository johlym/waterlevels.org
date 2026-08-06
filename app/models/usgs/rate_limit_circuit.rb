module Usgs
  # When USGS returns 429, trip this circuit so already-queued jobs stop hammering
  # the hourly request budget instead of retrying into a backlog.
  #
  # Circuits are per API-key identity (`tip`, `history_1`, `history_2`, …) so a
  # history-key 429 does not darken latest/catalog tip sync, and vice versa.
  class RateLimitCircuit
    KEY_PREFIX = "usgs:rate_limit_circuit"
    TIP_KEY = "tip"
    LEGACY_KEY = KEY_PREFIX # pre-namespaced key; treated as tip

    def self.open!(key_id: TIP_KEY, ttl: nil)
      Rails.cache.write(cache_key(key_id), true, expires_in: ttl || default_ttl)
    end

    def self.open?(key_id = TIP_KEY)
      id = normalize_key_id(key_id)
      return true if Rails.cache.exist?(cache_key(id))
      # Migrate: an old unscoped trip still blocks tip traffic.
      id == TIP_KEY && Rails.cache.exist?(LEGACY_KEY)
    end

    def self.clear!(key_id = TIP_KEY)
      id = normalize_key_id(key_id)
      Rails.cache.delete(cache_key(id))
      Rails.cache.delete(LEGACY_KEY) if id == TIP_KEY
    end

    def self.cache_key(key_id)
      "#{KEY_PREFIX}:#{normalize_key_id(key_id)}"
    end

    # Stay dark through the rest of the UTC hour (USGS budget window), with a
    # short floor so a trip near :59 still cools down.
    def self.default_ttl
      remaining = (Time.current.utc.end_of_hour - Time.current.utc).to_i + 1
      [ remaining, 5.minutes.to_i ].max.seconds
    end

    def self.normalize_key_id(key_id)
      raw = key_id.nil? || key_id == true ? TIP_KEY : key_id
      raw.to_s.presence || TIP_KEY
    end
    private_class_method :normalize_key_id
  end
end
