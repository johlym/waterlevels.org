# frozen_string_literal: true

# Periodic Honeycomb events for queue pressure and dataset completeness.
#
# One event per queue, one pressure event, and one coverage event per scope
# so an MCP query can GROUP BY pipeline.queue or pipeline.state. These are
# gauges: query them with MAX/AVG of the attribute, not COUNT of events.
class PipelineSignals
  # Hardcoded so an empty queue still reports depth 0. `default` also carries
  # mail and edge-cache purge, so its latency is not purely retention work.
  # Notifications are intentionally absent.
  DATA_QUEUES = %w[sync backfill iv_repair iv_repair_scar default].freeze

  class << self
    def record_queues!
      workers = workers_by_queue
      DATA_QUEUES.each { |name| emit_queue(name, workers) }
      record_pressure!
    end

    # +aggregates+ is the hash from AdminDashboardStats#compute_backfill_aggregates
    # (also returned by refresh_inventory_counters!). Pass the optional
    # snapshots in tests; production loads them here.
    def record_coverage!(aggregates, tip_freshness: nil, iv_repair_candidates: :unset, iv_scar_candidates: :unset)
      aggregates = aggregates || {}
      tip_freshness ||= AdminDashboardStats.new.tip_freshness_counts
      iv_repair = resolve_candidate_count(iv_repair_candidates) { AdminDashboardStats.last_iv_repair_candidates }
      iv_scar = resolve_candidate_count(iv_scar_candidates) { AdminDashboardStats.last_iv_scar_candidates }

      national = national_counts(aggregates)
      national[:history_ready_ratio] = ratio(national[:history_ready], national[:stations])
      national.merge!(tip_attributes(tip_freshness))
      national[:stations_needing_iv_repair] = iv_repair
      national[:stations_needing_iv_scar] = iv_scar
      emit_coverage(national.merge(scope: "national"))

      Array(aggregates[:per_state]).each do |row|
        state = row[:state_code].presence || row["state_code"].presence
        next if state.blank?

        emit_coverage(state_counts(row).merge(scope: "state", state: state))
      end
    end

    private

    def emit_queue(name, workers)
      require "sidekiq/api"
      queue = Sidekiq::Queue.new(name)
      Telemetry.gauge(
        Telemetry::QUEUE_SPAN,
        signal: "queue",
        queue: name,
        "queue.depth": queue.size.to_i,
        "queue.latency_s": queue.latency.to_f,
        "queue.workers": workers[name].to_i
      )
    rescue StandardError => e
      Rails.logger.warn("[PipelineSignals] queue #{name} #{e.class}: #{e.message}")
    end

    def record_pressure!
      require "sidekiq/api"
      stats = Sidekiq::Stats.new
      locks = AdminDashboardStats.new.pipeline_lock_counts
      Telemetry.gauge(
        Telemetry::PRESSURE_SPAN,
        signal: "pressure",
        retry_size: stats.retry_size.to_i,
        dead_size: stats.dead_size.to_i,
        scheduled_size: stats.scheduled_size.to_i,
        history_backfill_locks: locks[:history_backfill_locks].to_i,
        history_backfill_cooldowns: locks[:history_backfill_cooldowns].to_i,
        iv_repair_locks: locks[:iv_repair_locks].to_i,
        iv_repair_cooldowns: locks[:iv_repair_cooldowns].to_i,
        "circuit.tip": Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY),
        "circuit.continuous": circuit_open?(:continuous),
        "circuit.daily": circuit_open?(:daily),
        "circuit.peaks": circuit_open?(:peaks),
        "circuit.iv_repair": circuit_open?(:iv_repair),
        "circuit.iv_repair2": circuit_open?(:iv_repair2),
        history_keys_exhausted: Usgs::HistoryKeyPool.exhausted?
      )
    rescue StandardError => e
      Rails.logger.warn("[PipelineSignals] pressure #{e.class}: #{e.message}")
    end

    def workers_by_queue
      require "sidekiq/api"
      counts = Hash.new(0)
      Sidekiq::ProcessSet.new.each do |process|
        next if process.respond_to?(:stopping?) && process.stopping?

        Array(process["queues"]).each { |queue| counts[queue.to_s] += 1 }
      end
      counts
    rescue StandardError => e
      Rails.logger.warn("[PipelineSignals] workers #{e.class}: #{e.message}")
      {}
    end

    def circuit_open?(purpose)
      Usgs::RateLimitCircuit.open?(Usgs::HistoryKeyPool.circuit_key_for(purpose))
    end

    def resolve_candidate_count(value)
      return yield if value == :unset

      value
    end

    def emit_coverage(attributes)
      Telemetry.gauge(Telemetry::COVERAGE_SPAN, signal: "coverage", **attributes.compact)
    end

    def national_counts(aggregates)
      per_state = Array(aggregates[:per_state])
      {
        stations: aggregates[:station_count].to_i,
        history_ready: aggregates[:stations_history_ready].to_i,
        stations_needing_history: aggregates[:stations_needing_history].to_i,
        stations_needing_deep: aggregates[:stations_needing_deep_history].to_i,
        stations_daily_tip_refresh: aggregates[:stations_daily_tip_refresh].to_i,
        stations_missing_year: aggregates[:stations_missing_year_history].to_i,
        stations_missing_continuous_anchor: per_state.sum { |row| row[:missing_continuous_anchor].to_i },
        stations_missing_continuous_tip: per_state.sum { |row| row[:missing_continuous_tip].to_i },
        stations_missing_daily_tip: per_state.sum { |row| row[:missing_daily_tip].to_i }
      }
    end

    def state_counts(row)
      {
        stations: row[:station_count].to_i,
        history_ready: row[:history_ready].to_i,
        stations_needing_history: row[:needing_history].to_i,
        stations_needing_deep: row[:needing_deep_history].to_i,
        stations_daily_tip_refresh: row[:daily_tip_refresh].to_i,
        stations_missing_year: row[:missing_year_history].to_i,
        stations_missing_continuous_anchor: row[:missing_continuous_anchor].to_i,
        stations_missing_continuous_tip: row[:missing_continuous_tip].to_i,
        stations_missing_daily_tip: row[:missing_daily_tip].to_i
      }
    end

    def tip_attributes(histogram)
      histogram = histogram || {}
      {
        tip_current: histogram[:current].to_i,
        tip_h1_plus: histogram[:h1_plus].to_i,
        tip_h6_plus: histogram[:h6_plus].to_i,
        tip_h24_plus: histogram[:h24_plus].to_i,
        tip_h72_plus: histogram[:h72_plus].to_i,
        tip_stale: histogram[:stale].to_i
      }
    end

    def ratio(part, whole)
      return if whole.to_i <= 0

      (part.to_f / whole).round(4)
    end
  end
end
