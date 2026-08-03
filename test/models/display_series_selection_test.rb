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
end
