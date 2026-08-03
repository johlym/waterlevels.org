class SiteStats
  CACHE_KEY = "site_stats/v2".freeze
  TTL = 10.minutes
  # Marketing totals don't need exact row counts; fall back to COUNT for small tables.
  APPROX_COUNT_THRESHOLD = 1_000

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
        station_count: MonitoringLocation.count,
        measurement_count: approximate_or_exact_count(ContinuousObservation) +
          approximate_or_exact_count(DailyObservation) +
          approximate_or_exact_count(PeakObservation),
        updates_per_hour: ContinuousObservation.where(observed_at: 1.hour.ago..).count,
        flood_alert_count: MonitoringLocation.flood_alert.count
      }
    end

    private

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
