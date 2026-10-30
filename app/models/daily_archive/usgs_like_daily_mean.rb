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
      self.class.means_for(time_series: @time_series, days: [ @day ], location: @location)[@day]
    end

    # One continuous read for every requested local day on this series.
    def self.means_for(time_series:, days:, location: nil)
      days = Array(days).map(&:to_date).uniq.sort
      return {} if days.empty?

      location ||= time_series.monitoring_location
      zone = Usgs::TimeZones.resolve(location.time_zone, state_code: location.state_code)
      return {} if zone.blank?

      range_start = zone.local(days.first.year, days.first.month, days.first.day).beginning_of_day
      range_end = zone.local(days.last.year, days.last.month, days.last.day).beginning_of_day + 1.day
      wanted = days.to_set
      buckets = Hash.new { |hash, key| hash[key] = [] }
      time_series.continuous_observations
        .where(observed_at: range_start...range_end)
        .pluck(:observed_at, :value)
        .each do |observed_at, value|
          day = observed_at.in_time_zone(zone).to_date
          buckets[day] << value.to_f if wanted.include?(day)
        end

      days.index_with { |day| point_for(day, buckets[day], zone) }
    end

    def self.rollup_day_for(location, as_of: Time.current)
      zone = Usgs::TimeZones.resolve(location.time_zone, state_code: location.state_code) || Time.zone
      local_today = as_of.in_time_zone(zone).to_date
      local_today - DailyArchive::CONTINUOUS_ROLLUP_AFTER
    end

    private

    def self.point_for(day, values, zone)
      return nil if values.blank?

      starts = zone.local(day.year, day.month, day.day).beginning_of_day
      ends = starts + 1.day
      return nil unless adequate_coverage?(values, starts, ends)

      {
        "d" => day.iso8601,
        "v" => (values.sum / values.size).round(6),
        "s" => DailyArchive::SOURCE_DERIVED
      }
    end

    def self.adequate_coverage?(values, starts, ends)
      # Infer cadence from first/last spacing when possible; else assume 15 minutes.
      expected_slot = 15.minutes
      span = ends - starts
      expected = (span / expected_slot).floor
      return false if expected <= 0

      values.size >= (expected * DailyArchive::COVERAGE_RATIO).ceil
    end
  end
end
