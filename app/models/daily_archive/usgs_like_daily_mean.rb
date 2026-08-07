module DailyArchive
  # Approximate USGS daily mean (00003): arithmetic mean of continuous IV
  # from midnight→midnight in the monitoring location's local time zone.
  class UsgsLikeDailyMean
    def initialize(time_series:, day:, location: nil)
      @time_series = time_series
      @day = day.to_date
      @location = location || time_series.monitoring_location
    end

    def compute
      zone = Usgs::TimeZones.resolve(@location.time_zone, state_code: @location.state_code)
      return nil if zone.blank?

      starts = zone.local(@day.year, @day.month, @day.day).beginning_of_day
      ends = starts + 1.day
      values = @time_series.continuous_observations
        .where(observed_at: starts...ends)
        .pluck(:value)
        .map(&:to_f)
      return nil if values.empty?
      return nil unless adequate_coverage?(values, starts, ends)

      mean = values.sum / values.size
      {
        "d" => @day.iso8601,
        "v" => mean.round(6),
        "s" => DailyArchive::SOURCE_DERIVED
      }
    end

    def self.rollup_day_for(location, as_of: Time.current)
      zone = Usgs::TimeZones.resolve(location.time_zone, state_code: location.state_code) || Time.zone
      local_today = as_of.in_time_zone(zone).to_date
      local_today - DailyArchive::CONTINUOUS_ROLLUP_AFTER
    end

    private

    def adequate_coverage?(values, starts, ends)
      # Infer cadence from first/last spacing when possible; else assume 15 minutes.
      expected_slot = 15.minutes
      span = ends - starts
      expected = (span / expected_slot).floor
      return false if expected <= 0

      values.size >= (expected * DailyArchive::COVERAGE_RATIO).ceil
    end
  end
end
