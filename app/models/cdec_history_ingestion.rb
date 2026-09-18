# Pages CDEC daily reservoir elevation into the DailyArchive for curated
# California reservoirs. No continuous_observations — sensor 6 is daily.
class CdecHistoryIngestion
  include ActiveModel::Model

  DEFAULT_CHUNK_DAYS = 365
  TIP_LOOKBACK_DAYS = 45

  attr_accessor :client, :progress

  def initialize(client: Cdec::Client.new, progress: nil)
    @client = client
    @progress = progress
  end

  def perform(location, years: HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS)
    entry = Cdec::ReservoirCatalog.find_by_site_number(location.site_number)
    raise ArgumentError, "No CDEC catalog entry for #{location.site_number}" unless entry

    series = location.time_series.find_by!(
      provider_series_id: Cdec::ReservoirCatalog.provider_series_id(entry.station_id, entry.sensor_num)
    )

    end_on = Date.current
    start_on = end_on - years.years
    ingest_window!(series, entry, start_on: start_on, end_on: end_on)
    CdecReservoirSync.new(client: client, progress: progress).sync_entry!(entry)
    series
  end

  def ingest_recent_tip!(location, days: TIP_LOOKBACK_DAYS)
    entry = Cdec::ReservoirCatalog.find_by_site_number(location.site_number)
    return unless entry

    series = location.time_series.find_by(
      provider_series_id: Cdec::ReservoirCatalog.provider_series_id(entry.station_id, entry.sensor_num)
    )
    return unless series

    end_on = Date.current
    start_on = end_on - days.days
    ingest_window!(series, entry, start_on: start_on, end_on: end_on)
  end

  private

  def ingest_window!(series, entry, start_on:, end_on:)
    unless DailyArchive.archive_writes_enabled?
      progress&.step("archive_writes_disabled series=#{series.id}")
      return 0
    end

    total = 0
    cursor = start_on
    while cursor <= end_on
      chunk_end = [ cursor + DEFAULT_CHUNK_DAYS.days - 1.day, end_on ].min
      points = fetch_points(entry, after: cursor, before: chunk_end)
      if points.any?
        written = DailyArchive::Writer.new.upsert(time_series_id: series.id, points: points)
        total += written
        progress&.step(
          "series=#{series.id} #{cursor}..#{chunk_end} points=#{points.size} written=#{written}"
        )
      end
      cursor = chunk_end + 1.day
    end
    total
  end

  def fetch_points(entry, after:, before:)
    points = []
    client.each_reading(
      station_id: entry.station_id,
      sensor_num: entry.sensor_num,
      start_on: after,
      end_on: before
    ) do |row|
      next if Cdec::Client.missing_value?(row["value"])

      observed_on = Date.parse(row["date"].to_s)
      points << {
        "d" => observed_on.iso8601,
        "v" => row["value"].to_f,
        "s" => DailyArchive::SOURCE_USGS,
        "a" => "Provisional"
      }
    rescue ArgumentError, TypeError
      next
    end
    points
  rescue Cdec::Client::Error => e
    Rails.logger.warn("CdecHistoryIngestion fetch error: #{e.class}: #{e.message}")
    points
  end
end
