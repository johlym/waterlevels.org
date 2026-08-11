module Usgs
  # Purpose-pinned history API keys so continuous / daily / peaks / IV-repair
  # traffic (and their 429 circuits) stay isolated from each other and from
  # tip/catalog sync.
  #
  # Production: set USGS_API_HISTORY_CONTINUOUS_KEY, USGS_API_HISTORY_DAILY_KEY,
  # USGS_API_HISTORY_PEAKS_KEY, and USGS_API_HISTORY_IVREPAIR_KEY.
  # Local/test fallback: USGS_API_KEY (tip circuit) when a purpose key is unset.
  class HistoryKeyPool
    PURPOSE_ROLES = {
      continuous: "Cold continuous / IV archive",
      daily: "Daily history",
      peaks: "Peaks",
      iv_repair: "IV gap repair"
    }.freeze

    PURPOSES = {
      continuous: {
        env: "USGS_API_HISTORY_CONTINUOUS_KEY",
        circuit_key: "history_continuous"
      },
      daily: {
        env: "USGS_API_HISTORY_DAILY_KEY",
        circuit_key: "history_daily"
      },
      peaks: {
        env: "USGS_API_HISTORY_PEAKS_KEY",
        circuit_key: "history_peaks"
      },
      iv_repair: {
        env: "USGS_API_HISTORY_IVREPAIR_KEY",
        circuit_key: "history_iv_repair"
      }
    }.freeze

    # USGS documented hourly request budget per API key (planning reference only;
    # we do not try to mirror USGS's remaining quota locally).
    HOURLY_REQUEST_LIMIT = 1000
    # Rough planning costs for batch station ceilings.
    PHASE1_REQUESTS_PER_STATION = 12 # cold 1y: continuous pages + daily + peaks
    DEEP_REQUESTS_PER_STATION = 2 # 1y→3y daily gap is usually 1–2 pages
    IV_REPAIR_REQUESTS_PER_STATION = 2 # gap-sized continuous pulls

    def self.purposes
      PURPOSES.keys
    end

    def self.configured?(purpose = nil)
      if purpose.nil?
        PURPOSES.any? { |name, _| purpose_configured?(name) }
      else
        purpose_configured?(purpose)
      end
    end

    def self.purpose_configured?(purpose)
      ENV[env_for(purpose)].to_s.strip.present?
    end
    private_class_method :purpose_configured?

    def self.env_for(purpose)
      meta_for(purpose)[:env]
    end

    def self.circuit_key_for(purpose)
      if purpose_configured?(purpose)
        meta_for(purpose)[:circuit_key]
      else
        RateLimitCircuit::TIP_KEY
      end
    end

    def self.available?(purpose)
      !RateLimitCircuit.open?(circuit_key_for(purpose))
    end

    # True when no history purpose can make USGS calls (all purpose circuits open,
    # or the shared tip fallback circuit is open when keys are unset).
    def self.exhausted?
      purposes.none? { |purpose| available?(purpose) }
    end

    def self.phase1_available?
      available?(:continuous) || available?(:daily)
    end

    def self.deep_available?
      available?(:daily)
    end

    def self.iv_repair_available?
      available?(:iv_repair)
    end

    def self.claim!(purpose)
      purpose = normalize_purpose!(purpose)
      circuit_key = circuit_key_for(purpose)
      if RateLimitCircuit.open?(circuit_key)
        raise Client::RateLimitError, "USGS rate limit circuit open key=#{circuit_key}"
      end

      {
        purpose: purpose,
        api_key: api_key_for(purpose),
        circuit_key: circuit_key,
        env: configured?(purpose) ? env_for(purpose) : "USGS_API_KEY"
      }
    end

    # Tip + purpose-pinned history keys for the admin dashboard.
    def self.dashboard_statuses
      tip_configured = ENV["USGS_API_KEY"].to_s.strip.present?
      tip = {
        key: RateLimitCircuit::TIP_KEY,
        purpose: :tip,
        env: "USGS_API_KEY",
        configured: tip_configured,
        open: RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY),
        role: "Catalog / latest / bootstrap"
      }

      history = PURPOSES.map do |purpose, meta|
        effective = circuit_key_for(purpose)
        {
          key: meta[:circuit_key],
          purpose: purpose,
          env: meta[:env],
          configured: purpose_configured?(purpose),
          open: RateLimitCircuit.open?(effective),
          effective_circuit_key: effective,
          role: PURPOSE_ROLES.fetch(purpose),
          fallback_to_tip: !purpose_configured?(purpose)
        }
      end

      { tip: tip, history: history, exhausted: exhausted? }
    end

    def self.meta_for(purpose)
      PURPOSES.fetch(normalize_purpose!(purpose))
    end
    private_class_method :meta_for

    def self.normalize_purpose!(purpose)
      key = purpose.to_sym
      return key if PURPOSES.key?(key)

      raise ArgumentError, "unknown history API purpose=#{purpose.inspect}"
    end
    private_class_method :normalize_purpose!

    def self.api_key_for(purpose)
      if purpose_configured?(purpose)
        ENV[env_for(purpose)].to_s.strip
      else
        ENV["USGS_API_KEY"].presence
      end
    end
    private_class_method :api_key_for
  end
end
