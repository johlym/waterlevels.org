# Upserts curated USBR RISE reservoirs into monitoring_locations / time_series /
# latest_observations and denormalizes tips for map/gauge display.
class UsbrReservoirSync
  include ActiveModel::Model

  attr_accessor :client, :progress

  def initialize(client: Usbr::Client.new, progress: nil)
    @client = client
    @progress = progress
  end

  def perform(entries: Usbr::ReservoirCatalog.active_entries)
    Array(entries).sum { |entry| sync_entry!(entry) }
  end

  def sync_entry!(entry)
    Telemetry.in_span(
      "usbr.reservoir_sync",
      attributes: {
        "app.operation" => "usbr.reservoir_sync",
        "app.site_number" => entry.site_number,
        "app.state" => entry.state_code
      }
    ) do
      location = upsert_location!(entry)
      series = upsert_series!(location, entry)
      tip = fetch_latest_result(entry)
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

  def upsert_location!(entry)
    derived = MonitoringLocation.derived_names_for(entry.name)
    attrs = {
      data_provider: DataProviders::USBR,
      agency_code: "USBR",
      agency_name: DataProviders.label_for(DataProviders::USBR),
      provider_location_id: Usbr::ReservoirCatalog.provider_location_id(entry.rise_location_id),
      site_number: entry.site_number,
      name: entry.name,
      display_name: derived[:display_name],
      search_name: derived[:search_name],
      slug: MonitoringLocation.slug_for(entry.name),
      site_type_code: "LK",
      site_type_name: "Lake, Reservoir, Impoundment",
      latitude: entry.latitude,
      longitude: entry.longitude,
      state_code: entry.state_code,
      state_name: entry.state_name,
      time_zone: entry.time_zone,
      active: true,
      metadata_synced_at: Time.current
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
    series_id = Usbr::ReservoirCatalog.provider_series_id(entry.elevation_item_id)
    series = location.time_series.find_or_initialize_by(provider_series_id: series_id)
    series.assign_attributes(
      parameter_code: entry.parameter_code,
      parameter_name: Usbr::ParameterCodes.label_for(entry.parameter_code),
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

  def fetch_latest_result(entry)
    # RISE returns newest first; take the first page row.
    attrs = nil
    client.each_result(entry.elevation_item_id, items_per_page: 1) do |row|
      attrs = row
      break
    end
    return if attrs.blank?

    observed_at = Time.zone.parse(attrs["dateTime"].to_s)
    value = attrs["result"]
    return if observed_at.blank? || value.nil?

    { observed_at: observed_at, value: value.to_d, raw: attrs }
  rescue ArgumentError, TypeError
    nil
  end

  def upsert_tip!(series, tip, entry)
    now = Time.current
    LatestObservation.upsert(
      {
        time_series_id: series.id,
        observed_at: tip[:observed_at],
        value: tip[:value],
        unit_of_measure: entry.unit_of_measure,
        approval_status: tip.dig(:raw, "status").presence || "Provisional",
        qualifier: nil,
        source_last_modified_at: tip[:observed_at],
        synced_at: now,
        created_at: now,
        updated_at: now
      },
      unique_by: :time_series_id
    )
  end
end
