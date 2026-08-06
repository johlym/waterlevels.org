require "test_helper"

class DisplaySeriesSelectionTest < ActiveSupport::TestCase
  test "selects all water level variants and prefers gage height for denormalized map values" do
    location = create(:monitoring_location, has_discharge: false, has_temperature: false)
    # One series already selected in-memory/DB — update_all + update! must not no-op.
    gage = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true,
      usgs_time_series_id: "ts-gage"
    )
    ngvd = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "62614",
      measurement_kind: "water_level",
      selected_for_display: false,
      usgs_time_series_id: "ts-ngvd"
    )
    LatestObservation.create!(time_series: gage, value: 541.24, unit_of_measure: "ft", observed_at: 1.hour.ago, synced_at: Time.current)
    LatestObservation.create!(time_series: ngvd, value: 540.74, unit_of_measure: "ft", observed_at: 1.hour.ago, synced_at: Time.current)

    DisplaySeriesSelection.apply!(location.reload)

    assert_equal [ true, true ], [ gage.reload.selected_for_display, ngvd.reload.selected_for_display ]
    assert_equal "00065", location.reload.latest_water_level_parameter_code
    assert_in_delta 541.24, location.latest_water_level_value, 0.001
  end

  test "denormalize! refreshes tip columns from selected latest observations" do
    location = create(
      :monitoring_location,
      latest_water_level_value: 1.0,
      latest_water_level_parameter_code: "00065",
      latest_water_level_unit: "ft",
      latest_observed_at: 3.days.ago
    )
    series = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    observed_at = Time.utc(2026, 8, 5, 15, 0, 0)
    LatestObservation.create!(
      time_series: series,
      value: 8.25,
      unit_of_measure: "ft",
      observed_at: observed_at,
      synced_at: Time.current
    )

    DisplaySeriesSelection.denormalize!(location.reload)

    location.reload
    assert_in_delta 8.25, location.latest_water_level_value, 0.001
    assert_equal "00065", location.latest_water_level_parameter_code
    assert_equal observed_at, location.latest_observed_at
  end

  test "denormalize! skips USGS temperature sentinels that overflow decimal(8,3)" do
    location = create(
      :monitoring_location,
      has_temperature: true,
      latest_temperature_c: 12.5,
      latest_observed_at: 3.days.ago
    )
    series = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true
    )
    observed_at = Time.utc(2026, 8, 5, 15, 0, 0)
    LatestObservation.create!(
      time_series: series,
      value: -100_000,
      unit_of_measure: "degC",
      observed_at: observed_at,
      synced_at: Time.current
    )

    assert_nothing_raised { DisplaySeriesSelection.denormalize!(location.reload) }

    location.reload
    assert_nil location.latest_temperature_c
    assert_equal observed_at, location.latest_observed_at
  end
end
