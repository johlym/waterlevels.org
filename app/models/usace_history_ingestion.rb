# Pages CWMS daily elevation into the DailyArchive (R2/local) for curated
# USACE projects. No continuous_observations in P2 — tips may come from
# sub-daily series, but charts stay daily_only via the archive path.
class UsaceHistoryIngestion
  include ActiveModel::Model

  DEFAULT_CHUNK_DAYS = 365
  TIP_LOOKBACK_DAYS = 45

  attr_accessor :client, :progress

  def initialize(client: Usace::Client.new, progress: nil)
    @client = client
    @progress = progress
  end

  def perform(location, years: 3)
    entry = Usace::ProjectCatalog.find_by_site_number(location.site_number)
    raise ArgumentError, "No USACE catalog entry for #{location.site_number}" unless entry

    series = location.time_series.find_by!(
      provider_series_id: Usace::ProjectCatalog.provider_series_id(entry.office, entry.history_timeseries_name)
    )

    end_on = Date.current
    start_on = end_on - years.years
    ingest_window!(series, entry, start_on: start_on, end_on: end_on)
    UsaceProjectSync.new(client: client, progress: progress).sync_entry!(entry)
    series
  end

  def ingest_recent_tip!(location, days: TIP_LOOKBACK_DAYS)
    entry = Usace::ProjectCatalog.find_by_site_number(location.site_number)
    return unless entry

    series = location.time_series.find_by(
      provider_series_id: Usace::ProjectCatalog.provider_series_id(entry.office, entry.history_timeseries_name)
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
    begin_at = Time.zone.parse("#{after.iso8601} 00:00:00").utc
    end_at = Time.zone.parse("#{before.iso8601} 23:59:59").utc
    by_day = {}

    client.each_timeseries_value(
      name: entry.history_timeseries_name,
      office: entry.office,
      begin_at: begin_at,
      end_at: end_at,
      unit: entry.unit_of_measure
    ) do |observed_at, value, _quality|
      day = observed_at.in_time_zone(Time.zone).to_date
      by_day[day] = value
    end

    by_day.keys.sort.each do |day|
      points << {
        "d" => day.iso8601,
        "v" => by_day[day].to_f,
        "s" => DailyArchive::SOURCE_USGS,
        "a" => "Provisional"
      }
    end
    points
  rescue Usace::Client::Error, ArgumentError, TypeError => e
    Rails.logger.warn("UsaceHistoryIngestion parse error: #{e.class}: #{e.message}")
    points
  end
end
