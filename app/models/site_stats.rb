class SiteStats
  CACHE_KEY = "site_stats/v6".freeze
  MEASUREMENT_CACHE_KEY = "site_stats/measurements/v1".freeze
  TTL = 10.minutes
  # A national flood run walks every state and used to rebuild this from
  # scratch each time. Keep the exact totals long enough that those states
  # share one scan. Tip sync refreshes the snapshot hourly. /admin counts
  # the observation tables on its own.
  MEASUREMENT_TTL = 3.hours
  # Used only by the optional ContinuousInventory estimate. /admin and the
  # homepage measurement total use COUNT — reltuples stays frozen until
  # ANALYZE, and n_live_tup is often 0, so either estimate disagrees with
  # the table after a load or a prune.
  APPROX_COUNT_THRESHOLD = 1_000
  UPDATES_TIME_ZONE = "America/Los_Angeles".freeze

  class << self
    def snapshot
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { compute }
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
    # gap-free R2 shard are one measurement, not two. Shared with /admin so
    # the homepage total and the dashboard total cannot drift.
    def observation_totals
      daily = row_count(DailyObservation)
      overlap = DailyArchive.duplicated_postgres_daily_count
      continuous = row_count(ContinuousObservation)
      peaks = row_count(PeakObservation)
      archive = DailyArchive.cold_archive_point_count
      {
        continuous: continuous,
        daily: daily,
        overlap: overlap,
        peaks: peaks,
        archive: archive,
        measurement_count: continuous + [ daily - overlap, 0 ].max + peaks + archive
      }
    end

    def row_count(model)
      model.count
    end

    # Exact COUNT of continuous/daily/peak rows plus the archive-overlap
    # join. Flood sync passes refresh: false so a national run does not
    # repeat that scan once per state after old daily rows are still present.
    def measurement_snapshot(refresh:)
      unless refresh
        cached = read_measurement_snapshot
        return cached if cached
      end

      totals = observation_totals
      payload = {
        measurement_count: totals[:measurement_count],
        updates_today: ContinuousObservation.where(observed_at: pacific_today_range).count
      }
      Rails.cache.write(MEASUREMENT_CACHE_KEY, payload, expires_in: MEASUREMENT_TTL)
      payload
    end

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

    private

    def pacific_today_range
      zone = Time.find_zone!(UPDATES_TIME_ZONE)
      zone.now.all_day
    end
  end
end
