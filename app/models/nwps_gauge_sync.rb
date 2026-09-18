# Upserts curated NWPS gauges (no usgsId) as first-class monitoring locations.
# FloodStageSync stays USGS-only enrichment — this path owns primary NWPS rows.
class NwpsGaugeSync
  include ActiveModel::Model

  # Curated sync only hits a handful of endpoints; use a mild pause so we do not
  # share the flood-sync 30s budget on every tip refresh.
  DEFAULT_REQUEST_PAUSE_MS = 2_000

  attr_accessor :client, :progress

  def initialize(client: nil, progress: nil)
    @client = client || Nwps::Client.new(request_pause_ms: default_request_pause_ms)
    @progress = progress
  end

  def perform(entries: Nwps::GaugeCatalog.active_entries)
    Array(entries).sum { |entry| sync_entry!(entry) }
  end

  def sync_entry!(entry)
    Telemetry.in_span(
      "nwps.gauge_sync",
      attributes: {
        "app.operation" => "nwps.gauge_sync",
        "app.site_number" => entry.site_number,
        "app.state" => entry.state_code,
        "app.nwps_lid" => entry.lid
      }
    ) do
      detail = client.gauge(entry.lid)
      if detail.blank?
        progress&.step("site=#{entry.site_number} tip=missing detail")
        return 0
      end

      usgs_id = detail["usgsId"].to_s.strip
      if usgs_id.present?
        progress&.step("site=#{entry.site_number} skipped usgsId=#{usgs_id}")
        return 0
      end

      location = upsert_location!(entry, detail)
      series = upsert_series!(location, entry)
      tip = tip_from_detail(detail)
      if tip
        upsert_tip!(series, tip, entry)
        DisplaySeriesSelection.apply!(location.reload)
      else
        progress&.step("site=#{entry.site_number} tip=missing")
      end

      StationSnapshotCache.warm(location.reload)
      StateListingCache.warm(entry.state_code)
      progress&.step("site=#{entry.site_number} tip=#{tip ? tip[:value] : 'nil'}")
      1
    end
  end

  private

  def default_request_pause_ms
    return 0 if Rails.env.test?

    ENV.fetch("NWPS_GAUGE_REQUEST_PAUSE_MS", DEFAULT_REQUEST_PAUSE_MS.to_s).to_i
  end

  def upsert_location!(entry, detail)
    derived = MonitoringLocation.derived_names_for(entry.name)
    observed = (detail["status"] || {})["observed"] || {}
    forecast = (detail["status"] || {})["forecast"] || {}
    category = Nwps::FloodCategories.effective(
      observed["floodCategory"],
      forecast["floodCategory"]
    )
    thresholds = (detail["flood"] || {})["categories"] || {}

    attrs = {
      data_provider: DataProviders::NWPS,
      agency_code: "NWS",
      agency_name: DataProviders.label_for(DataProviders::NWPS),
      provider_location_id: Nwps::GaugeCatalog.provider_location_id(entry.lid),
      site_number: entry.site_number,
      name: entry.name,
      display_name: derived[:display_name],
      search_name: derived[:search_name],
      slug: MonitoringLocation.slug_for(entry.name),
      site_type_code: "ST",
      site_type_name: "Stream",
      latitude: entry.latitude,
      longitude: entry.longitude,
      state_code: entry.state_code,
      state_name: entry.state_name,
      time_zone: entry.time_zone,
      active: true,
      metadata_synced_at: Time.current,
      nwps_lid: entry.lid,
      nwps_matched: true,
      nwps_synced_at: Time.current,
      flood_category: category,
      flood_category_observed_at: parse_time(observed["validTime"]) || Time.current,
      flood_stage_action: Nwps::FloodCategories.stage_value(thresholds.dig("action", "stage")),
      flood_stage_minor: Nwps::FloodCategories.stage_value(thresholds.dig("minor", "stage")),
      flood_stage_moderate: Nwps::FloodCategories.stage_value(thresholds.dig("moderate", "stage")),
      flood_stage_major: Nwps::FloodCategories.stage_value(thresholds.dig("major", "stage"))
    }

    location = MonitoringLocation.find_by(site_number: entry.site_number)
    if location
      location.update!(attrs)
      location
    else
      MonitoringLocation.create!(attrs)
    end
  end

  def upsert_series!(location, entry)
    series_id = Nwps::GaugeCatalog.provider_series_id(entry.lid)
    series = location.time_series.find_or_initialize_by(provider_series_id: series_id)
    series.assign_attributes(
      parameter_code: entry.parameter_code,
      parameter_name: Nwps::ParameterCodes.label_for(entry.parameter_code),
      parameter_description: entry.parameter_description,
      unit_of_measure: entry.unit_of_measure,
      measurement_kind: "water_level",
      primary_series: true,
      selected_for_display: true,
      usgs_daily_absent: false
    )
    series.save!
    series
  end

  def tip_from_detail(detail)
    observed = (detail["status"] || {})["observed"] || {}
    value = observed["primary"]
    return if value.nil? || value.to_f <= -999

    observed_at = parse_time(observed["validTime"])
    return if observed_at.blank?

    { observed_at: observed_at, value: value.to_d }
  end

  def upsert_tip!(series, tip, entry)
    now = Time.current
    LatestObservation.upsert(
      {
        time_series_id: series.id,
        observed_at: tip[:observed_at],
        value: tip[:value],
        unit_of_measure: entry.unit_of_measure,
        approval_status: "Provisional",
        qualifier: nil,
        source_last_modified_at: tip[:observed_at],
        synced_at: now,
        created_at: now,
        updated_at: now
      },
      unique_by: :time_series_id
    )
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
