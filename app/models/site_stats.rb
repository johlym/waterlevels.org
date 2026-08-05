class SiteStats
  CACHE_KEY = "site_stats/v4".freeze
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
      {
        station_count: MonitoringLocation.active.count,
        measurement_count: approximate_or_exact_count(ContinuousObservation) +
          approximate_or_exact_count(DailyObservation) +
          approximate_or_exact_count(PeakObservation),
        updates_today: ContinuousObservation.where(observed_at: pacific_today_range).count,
        flood_alert_count: MonitoringLocation.flood_alert.count
      }
    end

    private

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
