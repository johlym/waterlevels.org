# Builds the Leaflet popup JSON for /api/map/stations.
# Prefers selected LatestObservation tips when they are fresher than (or as fresh
# as) denormalized MonitoringLocation columns — the same lag that PR #18 fixed
# for gauge detail pages.
class MapStationPayload
  def self.build(location)
    new(location).build
  end

  def initialize(location)
    @location = location
  end

  def build
    tips = tip_attrs
    use_tips = prefer_tips?(tips)

    water_level_code = use_tips ? tips[:latest_water_level_parameter_code] : location.latest_water_level_parameter_code
    water_level_value = use_tips ? tips[:latest_water_level_value] : location.latest_water_level_value
    water_level_unit = use_tips ? tips[:latest_water_level_unit] : location.latest_water_level_unit
    discharge_value = use_tips ? tips[:latest_discharge_value] : location.latest_discharge_value
    discharge_unit = use_tips ? tips[:latest_discharge_unit] : location.latest_discharge_unit
    temperature_c = use_tips ? tips[:latest_temperature_c] : location.latest_temperature_c
    observed_at = use_tips ? tips[:latest_observed_at] : location.latest_observed_at
    approval_status = use_tips ? tips[:latest_approval_status] : location.latest_approval_status

    {
      id: location.site_number,
      name: location.display_name,
      state: location.state_code,
      path: "/gauges/#{location.path_state}/#{location.to_param}",
      type: "station",
      stale: stale_for?(observed_at),
      has_water_level: location.has_water_level,
      has_discharge: location.has_discharge,
      has_temperature: location.has_temperature,
      nwps_matched: location.nwps_matched,
      flood_category: location.flood_category,
      flood_category_label: location.flood_category_short_label,
      flood_alert: location.flood_alert?,
      lat: location.latitude.to_f,
      lon: location.longitude.to_f,
      water_level: water_level_value&.to_f,
      water_level_unit: UnitLabel.format(water_level_unit),
      water_level_parameter_code: water_level_code,
      water_level_label: Usgs::ParameterCodes.label_for(water_level_code, fallback: "Water level"),
      discharge: discharge_value&.to_f,
      discharge_unit: UnitLabel.format(discharge_unit),
      temperature_c: temperature_c&.to_f,
      observed_at: observed_at&.iso8601,
      time_zone: location.time_zone,
      time_zone_identifier: location.time_zone_identifier,
      approval_status: approval_status,
      flood_stage_action: location.flood_stage_action&.to_f,
      flood_stage_minor: location.flood_stage_minor&.to_f,
      flood_stage_moderate: location.flood_stage_moderate&.to_f,
      flood_stage_major: location.flood_stage_major&.to_f
    }
  end

  private

  attr_reader :location

  def tip_attrs
    selected =
      if location.association(:selected_time_series).loaded?
        location.selected_time_series.to_a
      else
        location.selected_time_series.includes(:latest_observation).to_a
      end
    DisplaySeriesSelection.tip_attributes(location, selected: selected)
  end

  def prefer_tips?(tips)
    tip_at = tips[:latest_observed_at]
    return false if tip_at.blank?

    loc_at = location.latest_observed_at
    loc_at.blank? || tip_at.to_i >= loc_at.to_i
  end

  def stale_for?(observed_at)
    observed_at.blank? || observed_at < MonitoringLocation::STALE_AFTER.ago
  end
end
