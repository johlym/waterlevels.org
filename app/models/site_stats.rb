class SiteStats
  CACHE_KEY = "site_stats/v6".freeze
  TTL = 10.minutes
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

    def warm!
      compute.tap { |stats| Rails.cache.write(CACHE_KEY, stats, expires_in: TTL) }
    end

    def bust!
      Rails.cache.delete(CACHE_KEY)
    end

    def compute
      active_count = MonitoringLocation.active.count
      non_stale_count = MonitoringLocation.active.not_stale.count
      flood_alert_count = MonitoringLocation.flood_alert.count
      measurement_count = observation_totals[:measurement_count]
      updates_today = ContinuousObservation.where(observed_at: pacific_today_range).count

      emit_station_inventory!(
        stations_count: active_count,
        stations_non_stale_count: non_stale_count,
        flood_alert_count: flood_alert_count,
        measurement_count: measurement_count,
        updates_today: updates_today
      )

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

    # Periodic gauge-like event for Honeycomb time series of catalog health.
    # Emitted whenever stats are recomputed (hourly tip sync warm, boot, cache miss).
    def emit_station_inventory!(stations_count:, stations_non_stale_count:, flood_alert_count:, measurement_count:, updates_today:)
      Telemetry.in_root_span(
        "app.station_inventory",
        attributes: {
          "app.operation" => "station_inventory",
          "app.stations_count" => stations_count,
          "app.stations_non_stale_count" => stations_non_stale_count,
          "app.stations_stale_count" => [ stations_count - stations_non_stale_count, 0 ].max,
          "app.flood_alert_count" => flood_alert_count,
          "app.measurement_count" => measurement_count,
          "app.updates_today" => updates_today
        }
      ) { true }
    end

    def pacific_today_range
      zone = Time.find_zone!(UPDATES_TIME_ZONE)
      zone.now.all_day
    end
  end
end
