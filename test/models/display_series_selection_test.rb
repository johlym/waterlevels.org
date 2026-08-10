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

  test "apply! drops discontinued temperature when stage and flow are still reporting" do
    location = create(
      :monitoring_location,
      has_discharge: true,
      has_temperature: true
    )
    stage = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true,
      usgs_time_series_id: "ts-stage-active"
    )
    flow = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      selected_for_display: true,
      usgs_time_series_id: "ts-flow-active"
    )
    temp = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true,
      usgs_time_series_id: "ts-temp-ended"
    )
    LatestObservation.create!(time_series: stage, value: 4.2, unit_of_measure: "ft", observed_at: 1.hour.ago, synced_at: Time.current)
    LatestObservation.create!(time_series: flow, value: 120.0, unit_of_measure: "ft3/s", observed_at: 1.hour.ago, synced_at: Time.current)
    LatestObservation.create!(
      time_series: temp,
      value: 18.0,
      unit_of_measure: "degC",
      observed_at: Time.utc(2026, 7, 20, 12, 0, 0),
      synced_at: Time.current
    )

    DisplaySeriesSelection.apply!(location.reload)

    assert stage.reload.selected_for_display?
    assert flow.reload.selected_for_display?
    refute temp.reload.selected_for_display?
    location.reload
    assert location.has_water_level?
    assert location.has_discharge?
    refute location.has_temperature?
    assert_nil location.latest_temperature_c
  end

  test "apply! keeps last-known series when the whole station is quiet" do
    location = create(
      :monitoring_location,
      has_discharge: true,
      has_temperature: true
    )
    stage = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true,
      usgs_time_series_id: "ts-stage-stale"
    )
    temp = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true,
      usgs_time_series_id: "ts-temp-stale"
    )
    stale_at = 3.weeks.ago
    LatestObservation.create!(time_series: stage, value: 4.2, unit_of_measure: "ft", observed_at: stale_at, synced_at: Time.current)
    LatestObservation.create!(time_series: temp, value: 18.0, unit_of_measure: "degC", observed_at: stale_at, synced_at: Time.current)

    DisplaySeriesSelection.apply!(location.reload)

    assert stage.reload.selected_for_display?
    assert temp.reload.selected_for_display?
    location.reload
    assert location.has_water_level?
    assert location.has_temperature?
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
