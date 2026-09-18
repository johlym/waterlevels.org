# Pages RISE daily elevation results into the DailyArchive (R2/local) for
# curated USBR reservoirs. No continuous_observations — these series are daily-only.
class UsbrHistoryIngestion
  include ActiveModel::Model

  DEFAULT_CHUNK_DAYS = 365
  TIP_LOOKBACK_DAYS = 45

  attr_accessor :client, :progress

  def initialize(client: Usbr::Client.new, progress: nil)
    @client = client
    @progress = progress
  end

  def perform(location, years: HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS)
    entry = Usbr::ReservoirCatalog.find_by_site_number(location.site_number)
    raise ArgumentError, "No USBR catalog entry for #{location.site_number}" unless entry

    series = location.time_series.find_by!(
      provider_series_id: Usbr::ReservoirCatalog.provider_series_id(entry.elevation_item_id)
    )

    end_on = Date.current
    start_on = end_on - years.years
    ingest_window!(series, entry, start_on: start_on, end_on: end_on)
    UsbrReservoirSync.new(client: client, progress: progress).sync_entry!(entry)
    series
  end

  # Recent tip window only — used by the daily sync after catalog upsert.
  def ingest_recent_tip!(location, days: TIP_LOOKBACK_DAYS)
    entry = Usbr::ReservoirCatalog.find_by_site_number(location.site_number)
    return unless entry

    series = location.time_series.find_by(
      provider_series_id: Usbr::ReservoirCatalog.provider_series_id(entry.elevation_item_id)
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
    client.each_result(
      entry.elevation_item_id,
      after: after.iso8601,
      before: (before + 1.day).iso8601,
      items_per_page: Usbr::Client::DEFAULT_ITEMS_PER_PAGE
    ) do |attrs|
      observed_on = Date.parse(attrs["dateTime"].to_s[0, 10])
      value = attrs["result"]
      next if value.nil?

      # Official agency daily — reuse SOURCE_USGS merge priority until multi-agency
      # source_mix is generalized (shard enum remains usgs/derived/both).
      points << {
        "d" => observed_on.iso8601,
        "v" => value.to_f,
        "s" => DailyArchive::SOURCE_USGS,
        "a" => attrs["status"].presence || "Provisional"
      }
    end
    points
  rescue ArgumentError, TypeError => e
    Rails.logger.warn("UsbrHistoryIngestion parse error: #{e.class}: #{e.message}")
    points
  end
end
