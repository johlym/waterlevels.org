# Ingests NWPS stageflow observed points into continuous_observations for
# curated non-USGS NWPS gauges. Stageflow typically covers ~30 days of IV-like
# readings — enough for 24h/7d/30d hydrographs.
class NwpsHistoryIngestion
  include ActiveModel::Model

  SENTINEL = -999

  attr_accessor :client, :progress

  def initialize(client: nil, progress: nil)
    @client = client || Nwps::Client.new(
      request_pause_ms: (Rails.env.test? ? 0 : NwpsGaugeSync::DEFAULT_REQUEST_PAUSE_MS)
    )
    @progress = progress
  end

  def perform(location)
    entry = Nwps::GaugeCatalog.find_by_site_number(location.site_number)
    raise ArgumentError, "No NWPS catalog entry for #{location.site_number}" unless entry

    series = location.time_series.find_by!(
      provider_series_id: Nwps::GaugeCatalog.provider_series_id(entry.lid)
    )

    body = client.stageflow(entry.lid)
    if body.blank?
      progress&.step("site=#{entry.site_number} stageflow=missing")
      return series
    end

    points = observed_points(body)
    if points.empty?
      progress&.step("site=#{entry.site_number} stageflow=empty")
      return series
    end

    upsert_continuous!(series, points)
    NwpsGaugeSync.new(client: client, progress: progress).sync_entry!(entry)
    progress&.step("site=#{entry.site_number} continuous=#{points.size}")
    series
  end

  private

  def observed_points(body)
    observed = body["observed"] || {}
    Array(observed["data"]).filter_map do |row|
      value = row["primary"]
      next if value.nil? || value.to_f <= SENTINEL

      observed_at = Time.zone.parse(row["validTime"].to_s)
      next if observed_at.blank?

      { observed_at: observed_at.utc, value: value.to_d }
    rescue ArgumentError, TypeError
      nil
    end
  end

  def upsert_continuous!(series, points)
    now = Time.current
    rows = points.map do |point|
      {
        time_series_id: series.id,
        observed_at: point[:observed_at],
        value: point[:value],
        approval_status: "Provisional",
        qualifier: nil,
        created_at: now,
        updated_at: now
      }
    end

    rows = rows.each_with_object({}) { |row, uniq|
      uniq[[ row[:time_series_id], row[:observed_at].to_i ]] = row
    }.values

    ContinuousObservation.upsert_all(
      rows,
      unique_by: %i[time_series_id observed_at],
      update_only: %i[value approval_status qualifier]
    )
    TimeSeries.refresh_continuous_coverage!([ series.id ])
  end
end
