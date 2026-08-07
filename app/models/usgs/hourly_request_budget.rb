module Usgs
  # Per API-key hourly request counters (Redis) so we can approach the USGS
  # 1000 req/hr cap without waiting for a hard 429, and surface used/remaining
  # on the admin dashboard.
  #
  # Soft-cap trips RateLimitCircuit for the rest of the UTC hour once a key's
  # counter reaches USGS_HOURLY_SOFT_CAP (default 980). A real 429 still trips
  # the circuit via Client#handle_response as a safety net.
  class HourlyRequestBudget
    KEY_PREFIX = "usgs:req_count"
    HOURLY_LIMIT = HistoryKeyPool::HOURLY_REQUEST_LIMIT
    DEFAULT_SOFT_CAP = 980

    class << self
      def soft_cap
        raw = ENV.fetch("USGS_HOURLY_SOFT_CAP", DEFAULT_SOFT_CAP.to_s).to_i
        return DEFAULT_SOFT_CAP unless raw.positive?

        [ raw, HOURLY_LIMIT ].min
      end

      def hour_bucket(time = Time.current.utc)
        time.utc.strftime("%Y%m%d%H")
      end

      def cache_key(key_id, time = Time.current.utc)
        "#{KEY_PREFIX}:#{normalize_key_id(key_id)}:#{hour_bucket(time)}"
      end

      def used(key_id, time = Time.current.utc)
        redis_with_rescue { |r| r.get(cache_key(key_id, time)).to_i } || 0
      end

      def remaining(key_id, time = Time.current.utc)
        [ HOURLY_LIMIT - used(key_id, time), 0 ].max
      end

      def exhausted?(key_id, time = Time.current.utc)
        used(key_id, time) >= soft_cap
      end

      # Preflight: park the key before we spend another USGS call past soft-cap.
      def raise_if_exhausted!(key_id)
        return unless exhausted?(key_id)

        RateLimitCircuit.open!(key_id: key_id)
        raise Client::RateLimitError,
          "USGS hourly soft-cap exhausted key=#{normalize_key_id(key_id)} " \
          "used=#{used(key_id)} soft_cap=#{soft_cap}"
      end

      # Count one USGS HTTP attempt. Opens the circuit once soft-cap is reached.
      def record!(key_id, time = Time.current.utc)
        id = normalize_key_id(key_id)
        key = cache_key(id, time)
        count = redis_with_rescue do |r|
          n = r.incr(key)
          # Refresh TTL each write so a counter near :59 still expires cleanly.
          r.expire(key, ttl_seconds(time))
          n
        end
        return 0 if count.nil?

        RateLimitCircuit.open!(key_id: id) if count >= soft_cap
        count
      end

      def clear!(key_id, time = Time.current.utc)
        redis_with_rescue { |r| r.del(cache_key(key_id, time)) }
      end

      def clear_all!
        redis_with_rescue do |r|
          cursor = "0"
          loop do
            cursor, keys = r.scan(cursor, match: "#{KEY_PREFIX}:*", count: 200)
            r.del(*keys) if keys.any?
            break if cursor.to_s == "0"
          end
        end
      end

      def status_for(key_id, configured: true, env: nil, time: Time.current.utc)
        id = normalize_key_id(key_id)
        used_count = used(id, time)
        {
          key: id,
          env: env,
          configured: configured,
          used: used_count,
          budget: HOURLY_LIMIT,
          remaining: [ HOURLY_LIMIT - used_count, 0 ].max,
          soft_cap: soft_cap,
          soft_capped: used_count >= soft_cap,
          circuit_open: RateLimitCircuit.open?(id),
          hour: hour_bucket(time)
        }
      end

      # Tip + history keys for the admin dashboard.
      def dashboard_snapshot(time = Time.current.utc)
        tip_configured = ENV["USGS_API_KEY"].to_s.strip.present?
        tip = status_for(RateLimitCircuit::TIP_KEY, configured: tip_configured, env: "USGS_API_KEY", time: time)

        history_keys = HistoryKeyPool::ENTRIES.map do |entry|
          configured = ENV[entry[:env]].to_s.strip.present?
          status_for(entry[:circuit_key], configured: configured, env: entry[:env], time: time)
        end

        pool_rows = if HistoryKeyPool.configured?
          history_keys.select { |row| row[:configured] }
        else
          # Local/dev fallback: history traffic shares the tip key/budget.
          [ tip.merge(fallback: true) ]
        end

        pool_used = pool_rows.sum { |row| row[:used] }
        pool_budget = pool_rows.size * HOURLY_LIMIT
        {
          hour: hour_bucket(time),
          soft_cap: soft_cap,
          limit: HOURLY_LIMIT,
          tip: tip,
          history_keys: history_keys,
          history_pool: {
            used: pool_used,
            budget: pool_budget,
            remaining: [ pool_budget - pool_used, 0 ].max,
            key_count: pool_rows.size,
            available_keys: HistoryKeyPool.available_count,
            exhausted: HistoryKeyPool.exhausted?,
            fallback_to_tip: !HistoryKeyPool.configured?
          }
        }
      end

      private

      def normalize_key_id(key_id)
        raw = key_id.nil? || key_id == true ? RateLimitCircuit::TIP_KEY : key_id
        raw.to_s.presence || RateLimitCircuit::TIP_KEY
      end

      def ttl_seconds(time = Time.current.utc)
        # Survive a few minutes past hour rollover so late dashboard reads still
        # see the previous bucket if needed; next hour uses a new key.
        remaining = (time.utc.end_of_hour - time.utc).to_i + 5.minutes.to_i
        [ remaining, 60 ].max
      end

      def redis_with_rescue
        yield redis
      rescue StandardError => e
        Rails.logger.warn("[Usgs::HourlyRequestBudget] redis #{e.class}: #{e.message}")
        nil
      end

      def redis
        @redis ||= Redis.new(RedisConfig.options)
      end
    end
  end
end
