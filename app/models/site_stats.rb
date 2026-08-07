class SiteStats
  CACHE_KEY = "site_stats/v5".freeze
  TTL = 10.minutes
  # Marketing totals don't need exact row counts; fall back to COUNT for small tables.
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
      measurement_count = approximate_or_exact_count(ContinuousObservation) +
        approximate_or_exact_count(DailyObservation) +
        approximate_or_exact_count(PeakObservation)
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

    def approximate_or_exact_count(model)
      estimate = connection.select_value(
        "SELECT reltuples::bigint FROM pg_class WHERE oid = #{connection.quote(model.table_name)}::regclass"
      ).to_i
      return estimate if estimate >= APPROX_COUNT_THRESHOLD

      model.count
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
