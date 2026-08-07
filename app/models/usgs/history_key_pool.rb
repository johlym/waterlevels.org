module Usgs
  # Round-robins dedicated history API keys so backfill traffic does not share
  # USGS_API_KEY's hourly budget with latest/catalog tip sync.
  #
  # Production: set USGS_API_HISTORY_1_KEY and USGS_API_HISTORY_2_KEY.
  # Local/test fallback: USGS_API_KEY (same tip circuit) when history keys are unset.
  class HistoryKeyPool
    ENTRIES = [
      { env: "USGS_API_HISTORY_1_KEY", circuit_key: "history_1" },
      { env: "USGS_API_HISTORY_2_KEY", circuit_key: "history_2" }
    ].freeze
    COUNTER_KEY = "usgs:history_key_rr"
    # USGS documented hourly request budget per API key.
    HOURLY_REQUEST_LIMIT = 1000
    # Planning costs for sizing HistoryBackfillBatchJob so we approach the
    # per-key hourly cap without consistently overshooting into 429s.
    PHASE1_REQUESTS_PER_STATION = 20 # cold 1y: ~90d continuous pages + daily + peaks
    DEEP_REQUESTS_PER_STATION = 2 # 1y→3y daily gap is usually 1–2 pages

    def self.configured?
      configured_entries.any?
    end

    def self.configured_entries
      ENTRIES.filter_map do |entry|
        api_key = ENV[entry[:env]].to_s.strip.presence
        next unless api_key

        { api_key: api_key, circuit_key: entry[:circuit_key], env: entry[:env] }
      end
    end

    def self.entries
      configured = configured_entries
      return configured if configured.any?

      [ {
        api_key: ENV["USGS_API_KEY"].presence,
        circuit_key: RateLimitCircuit::TIP_KEY,
        env: "USGS_API_KEY"
      } ]
    end

    def self.available_entries
      entries.reject do |entry|
        RateLimitCircuit.open?(entry[:circuit_key]) ||
          HourlyRequestBudget.exhausted?(entry[:circuit_key])
      end
    end

    def self.available_count
      [ available_entries.size, 1 ].max
    end

    # Full hourly capacity for currently available keys (planning ceiling).
    def self.hourly_request_budget
      available_count * HOURLY_REQUEST_LIMIT
    end

    # Live remaining capacity this UTC hour across available keys.
    def self.remaining_request_budget
      available_entries.sum { |entry| HourlyRequestBudget.remaining(entry[:circuit_key]) }
    end

    def self.exhausted?
      available_entries.empty?
    end

    def self.claim!
      available = available_entries
      if available.empty?
        raise Client::RateLimitError, "USGS history rate limit circuits open"
      end

      available[next_index % available.size]
    end

    def self.next_index
      current = Rails.cache.read(COUNTER_KEY).to_i
      nxt = current + 1
      Rails.cache.write(COUNTER_KEY, nxt, expires_in: 24.hours)
      nxt
    end
    private_class_method :next_index
  end
end
