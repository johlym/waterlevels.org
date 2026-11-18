class SiteStats
  CACHE_KEY = "site_stats/v6".freeze
  MEASUREMENT_CACHE_KEY = "site_stats/measurements/v1".freeze
  TTL = 10.minutes
  # A national flood run walks every state and used to rebuild this from
  # scratch each time. Keep the published totals long enough that those states
  # share one read. Tip sync refreshes the snapshot hourly. /admin reads the
  # same observation_rollups sums.
  MEASUREMENT_TTL = 3.hours
  # Used only by the optional ContinuousInventory estimate. Homepage and
  # /admin measurement totals read observation_rollups (and the published
  # admin:inventory row), not COUNT(*). reltuples stays frozen until ANALYZE,
  # and n_live_tup is often 0, so either estimate disagrees with the table
  # after a load or a prune.
  APPROX_COUNT_THRESHOLD = 1_000
  UPDATES_TIME_ZONE = "America/Los_Angeles".freeze

  class << self
    def snapshot
      # Redis is a cache of the published counter. A flush reloads that row
      # instead of scanning observation tables. The counter job and warm!
      # are what republish from the rollup.
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { compute(refresh_measurements: false) }
    end

    def warm!(refresh_measurements: true)
      compute(refresh_measurements: refresh_measurements).tap do |stats|
        Rails.cache.write(CACHE_KEY, stats, expires_in: TTL)
      end
    end

    def bust!
      Rails.cache.delete(CACHE_KEY)
      Rails.cache.delete(MEASUREMENT_CACHE_KEY)
    end

    def compute(refresh_measurements: true)
      non_stale_count = MonitoringLocation.active.not_stale.count
      flood_alert_count = MonitoringLocation.flood_alert.count
      measurements = measurement_snapshot(refresh: refresh_measurements)
      measurement_count = measurements[:measurement_count]
      updates_today = measurements[:updates_today]

      {
        # Homepage "active" matches map Active status (not stale), not only the DB flag.
        station_count: non_stale_count,
        measurement_count: measurement_count,
        updates_today: updates_today,
        flood_alert_count: flood_alert_count
      }
    end

    # Unique stored measurements. Postgres dailies that already sit in a
    # gap-free R2 shard are one measurement, not two. Lifetimes come from
    # observation_rollups so the homepage total and the dashboard total share
    # one source.
    def observation_totals
      summary = ObservationRollup.summary
      daily = summary[:daily][:lifetime]
      overlap = DailyArchive.duplicated_postgres_daily_count
      continuous = summary[:continuous][:lifetime]
      peaks = summary[:peak][:lifetime]
      archive = DailyArchive.cold_archive_point_count
      {
        continuous: continuous,
        daily: daily,
        overlap: overlap,
        peaks: peaks,
        archive: archive,
        measurement_count: continuous + [ daily - overlap, 0 ].max + peaks + archive,
        updates_today: summary[:continuous][:today],
        continuous_last_24h: summary[:continuous][:last_24h],
        continuous_last_7d: summary[:continuous][:last_7d],
        continuous_last_24h_selected: summary[:continuous][:last_24h_selected]
      }
    end

    # Rollup sums, plus the published admin:inventory row when refresh is
    # false. Flood sync passes refresh: false so a national run does not
    # repeat the archive-overlap read once per state.
    def measurement_snapshot(refresh:)
      unless refresh
        cached = read_measurement_snapshot || published_measurements
        if cached
          Rails.cache.write(MEASUREMENT_CACHE_KEY, cached, expires_in: MEASUREMENT_TTL)
          return cached
        end
      end

      totals = observation_totals
      payload = {
        measurement_count: totals[:measurement_count],
        updates_today: totals[:updates_today]
      }
      publish_measurement_fields!(totals)
      Rails.cache.write(MEASUREMENT_CACHE_KEY, payload, expires_in: MEASUREMENT_TTL)
      payload
    end

    def published_measurements
      payload = AdminCounter.payload_for(AdminDashboardStats::INVENTORY_KEY)
      return unless payload

      count = payload[:measurement_count]
      updates = payload[:updates_today]
      return if count.nil? || updates.nil?

      { measurement_count: count.to_i, updates_today: updates.to_i }
    end

    def publish_measurement_fields!(totals)
      AdminCounter.merge_payload!(
        AdminDashboardStats::INVENTORY_KEY,
        continuous_observation_count: totals[:continuous],
        daily_observation_count: totals[:daily],
        daily_observation_overlap_count: totals[:overlap],
        peak_observation_count: totals[:peaks],
        archive_daily_observation_count: totals[:archive],
        measurement_count: totals[:measurement_count],
        updates_today: totals[:updates_today],
        continuous_last_24h: totals[:continuous_last_24h],
        continuous_last_7d: totals[:continuous_last_7d],
        continuous_last_24h_selected: totals[:continuous_last_24h_selected]
      )
    end
    private :published_measurements, :publish_measurement_fields!

    def read_measurement_snapshot
      raw = Rails.cache.read(MEASUREMENT_CACHE_KEY)
      return unless raw.is_a?(Hash)

      count = raw[:measurement_count] || raw["measurement_count"]
      updates = raw[:updates_today] || raw["updates_today"]
      return if count.nil? || updates.nil?

      { measurement_count: count.to_i, updates_today: updates.to_i }
    end
    private :measurement_snapshot, :read_measurement_snapshot

    # See APPROX_COUNT_THRESHOLD. The block runs only when COUNT is the
    # accurate choice, so large tables do not scan.
    def resolve_row_count(reltuples:, n_live_tup:)
      rel = reltuples.to_i
      live = n_live_tup.to_i
      return yield if rel < APPROX_COUNT_THRESHOLD
      return yield if live.positive? && live < APPROX_COUNT_THRESHOLD
      return live if live.positive?

      rel
    end
  end
end
