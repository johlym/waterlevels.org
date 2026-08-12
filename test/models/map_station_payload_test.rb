require "test_helper"

class MapStationPayloadTest < ActiveSupport::TestCase
  test "prefers fresher LatestObservation tips over lagging denormalized columns" do
    older = 5.days.ago
    newer = 2.days.ago
    location = create(
      :monitoring_location,
      site_number: "12199000",
      usgs_monitoring_location_id: "USGS-12199000",
      latest_water_level_value: 23.95,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_observed_at: older,
      latest_approval_status: "Provisional"
    )
    series = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    LatestObservation.create!(
      time_series: series,
      value: 23.80,
      unit_of_measure: "ft",
      observed_at: newer,
      synced_at: Time.current,
      approval_status: "Provisional"
    )

    payload = MapStationPayload.build(location.reload)
    assert_in_delta 23.80, payload[:water_level], 0.001
    assert_equal newer.iso8601, payload[:observed_at]
    assert_equal false, payload[:stale]
  end

  test "falls back to denormalized columns when no selected tips exist" do
    observed_at = Time.utc(2026, 8, 5, 14, 15, 0)
    location = create(
      :monitoring_location,
      latest_water_level_value: 7.5,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_discharge_value: 1200.0,
      latest_discharge_unit: "ft3/s",
      latest_observed_at: observed_at
    )

    payload = MapStationPayload.build(location)
    assert_in_delta 7.5, payload[:water_level], 0.001
    assert_in_delta 1200.0, payload[:discharge], 0.001
    assert_equal observed_at.iso8601, payload[:observed_at]
  end
end
