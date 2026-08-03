class SiteStats
  CACHE_KEY = "site_stats/v1".freeze
  TTL = 10.minutes

  class << self
    def snapshot
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { compute }
    end

    def compute
      {
        station_count: MonitoringLocation.count,
        measurement_count: ContinuousObservation.count + DailyObservation.count + PeakObservation.count,
        updates_per_hour: ContinuousObservation.where(observed_at: 1.hour.ago..).count
      }
    end
  end
end
