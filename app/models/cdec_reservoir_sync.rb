# Upserts curated CDEC reservoirs into monitoring_locations / time_series /
# latest_observations and denormalizes tips for map/gauge display.
class CdecReservoirSync
  include ActiveModel::Model

  TIP_LOOKBACK_DAYS = 14

  attr_accessor :client, :progress

  def initialize(client: Cdec::Client.new, progress: nil)
    @client = client
    @progress = progress
  end

  def perform(entries: Cdec::ReservoirCatalog.active_entries)
    Array(entries).sum { |entry| sync_entry!(entry) }
  end

  def sync_entry!(entry)
    Telemetry.in_span(
      "cdec.reservoir_sync",
      attributes: {
        "app.operation" => "cdec.reservoir_sync",
        "app.site_number" => entry.site_number,
        "app.state" => entry.state_code
      }
    ) do
      location = upsert_location!(entry)
      series = upsert_series!(location, entry)
      tip = fetch_latest_tip(entry)
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
      data_provider: DataProviders::CDEC,
      agency_code: "CDEC",
      provider_location_id: Cdec::ReservoirCatalog.provider_location_id(entry.station_id),
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
    series_id = Cdec::ReservoirCatalog.provider_series_id(entry.station_id, entry.sensor_num)
    series = location.time_series.find_or_initialize_by(provider_series_id: series_id)
    series.assign_attributes(
      parameter_code: entry.parameter_code,
      parameter_name: Cdec::ParameterCodes.label_for(entry.parameter_code),
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

  def fetch_latest_tip(entry)
    end_on = Date.current
    start_on = end_on - TIP_LOOKBACK_DAYS.days
    latest = nil
    client.each_reading(
      station_id: entry.station_id,
      sensor_num: entry.sensor_num,
      start_on: start_on,
      end_on: end_on
    ) do |row|
      next if Cdec::Client.missing_value?(row["value"])

      observed_on = Date.parse(row["date"].to_s)
      latest = { observed_at: observed_on.in_time_zone.beginning_of_day, value: row["value"].to_d }
    rescue ArgumentError, TypeError
      next
    end
    latest
  rescue Cdec::Client::Error => e
    Rails.logger.warn("CdecReservoirSync tip fetch failed site=#{entry.site_number}: #{e.class}: #{e.message}")
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
end
