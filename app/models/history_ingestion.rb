class HistoryIngestion
  include ActiveModel::Model

  attr_accessor :client, :monitoring_location, :range, :progress

  DEFAULT_RANGE = "1y"
  # High-resolution continuous is capped; 1y charts use daily values.
  CONTINUOUS_RETENTION = 90.days
  DAILY_RETENTION = 1.year
  # A selected series is considered year-loaded once it has a daily point this old.
  DAILY_HISTORY_ANCHOR = 11.months
  CONTINUOUS_FRESHNESS = 7.days

  def initialize(monitoring_location:, range: DEFAULT_RANGE, client: Usgs::Client.new, progress: nil)
    @monitoring_location = monitoring_location
    @range = range
    @client = client
    @progress = progress
  end

  def perform
    progress&.step("site=#{monitoring_location.site_number} range=#{range}")
    monitoring_location.time_series.selected.find_each do |series|
      progress&.step("series=#{series.usgs_time_series_id} kind=#{series.measurement_kind} parameter=#{series.parameter_code}")
      ingest_continuous(series) if continuous_range?
      ingest_daily(series) if daily_range?
      ingest_peaks(series)
    end
    StationSnapshotCache.warm(monitoring_location)
    progress&.finish("site=#{monitoring_location.site_number}")
    true
  end

  private

  def continuous_range?
    %w[24h 7d 30d 1y].include?(range)
  end

  def daily_range?
    %w[1y 30d].include?(range) || range == "por"
  end

  # USGS continuous rejects bare ISO-8601 durations (P7D/PT24H) despite docs;
  # use an explicit RFC3339 interval instead.
  # For 1y, only pull continuous within CONTINUOUS_RETENTION — year history is daily.
  def continuous_datetime_param
    ends = Time.current.utc
    starts = case range
    when "24h" then 24.hours.ago.utc
    when "7d" then 7.days.ago.utc
    when "30d" then 30.days.ago.utc
    when "1y" then CONTINUOUS_RETENTION.ago.utc
    else
      CONTINUOUS_RETENTION.ago.utc
    end
    "#{starts.iso8601}/#{ends.iso8601}"
  end

  def ingest_continuous(series)
    count = 0
    client.each_collection_item(
      "continuous",
      monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
      parameter_code: series.parameter_code,
      datetime: continuous_datetime_param
    ) do |item|
      observed_at = Time.zone.parse(item["time"] || item["datetime"].to_s) rescue nil
      value = item["value"]
      next if observed_at.blank? || value.blank?

      ContinuousObservation.upsert(
        {
          time_series_id: series.id,
          observed_at: observed_at,
          value: value,
          approval_status: item["approval_status"],
          qualifier: item["qualifier"],
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[time_series_id observed_at]
      )
      count += 1
      progress&.increment
    end
    progress&.step("continuous upserted=#{count}")
  end

  def ingest_daily(series)
    start_date = case range
    when "1y", "por" then DAILY_RETENTION.ago.to_date
    else
      30.days.ago.to_date
    end
    count = 0
    client.each_collection_item(
      "daily",
      monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
      parameter_code: series.parameter_code,
      datetime: "#{start_date.iso8601}/#{Date.current.iso8601}"
    ) do |item|
      day = Date.parse(item["time"] || item["date"] || item["datetime"].to_s) rescue nil
      value = item["value"]
      next if day.blank? || value.blank?

      DailyObservation.upsert(
        {
          time_series_id: series.id,
          observed_on: day,
          value: value,
          approval_status: item["approval_status"],
          qualifier: item["qualifier"],
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[time_series_id observed_on]
      )
      count += 1
      progress&.increment
    end
    progress&.step("daily upserted=#{count}")
  end

  def ingest_peaks(series)
    return unless series.measurement_kind.in?(%w[water_level discharge])

    count = 0
    client.each_collection_item(
      "peaks",
      monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
      parameter_code: series.parameter_code
    ) do |item|
      value = item["value"]
      observed_at = Time.zone.parse(item["time"] || item["datetime"].to_s) rescue nil
      next if value.blank?

      water_year = item["water_year"] || (observed_at && water_year_for(observed_at))
      next if water_year.blank?

      PeakObservation.upsert(
        {
          time_series_id: series.id,
          water_year: water_year.to_i,
          observed_at: observed_at,
          value: value,
          peak_kind: "high",
          approval_status: item["approval_status"],
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[time_series_id water_year peak_kind]
      )
      count += 1
      progress&.increment
    end
    progress&.step("peaks upserted=#{count}")
  end

  def water_year_for(time)
    time.month >= 10 ? time.year + 1 : time.year
  end
end
