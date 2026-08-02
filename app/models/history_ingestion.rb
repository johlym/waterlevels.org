class HistoryIngestion
  include ActiveModel::Model

  attr_accessor :client, :monitoring_location, :range

  CONTINUOUS_RETENTION = 90.days

  def initialize(monitoring_location:, range: "7d", client: Usgs::Client.new)
    @monitoring_location = monitoring_location
    @range = range
    @client = client
  end

  def perform
    monitoring_location.time_series.selected.find_each do |series|
      ingest_continuous(series) if continuous_range?
      ingest_daily(series) if daily_range?
      ingest_peaks(series)
    end
    StationSnapshotCache.warm(monitoring_location)
    true
  end

  private

  def continuous_range?
    %w[24h 7d 30d].include?(range)
  end

  def daily_range?
    %w[1y 30d].include?(range) || range == "por"
  end

  def datetime_param
    case range
    when "24h" then "PT24H"
    when "7d" then "P7D"
    when "30d" then "P30D"
    when "1y" then "P1Y"
    else
      "#{1.year.ago.iso8601}/#{Time.current.iso8601}"
    end
  end

  def ingest_continuous(series)
    client.each_collection_item(
      "continuous",
      monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
      parameter_code: series.parameter_code,
      datetime: datetime_param
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
    end
  end

  def ingest_daily(series)
    start_date = range == "1y" ? 1.year.ago.to_date : 30.days.ago.to_date
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
    end
  end

  def ingest_peaks(series)
    return unless series.measurement_kind.in?(%w[water_level discharge])

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
    end
  end

  def water_year_for(time)
    time.month >= 10 ? time.year + 1 : time.year
  end
end
