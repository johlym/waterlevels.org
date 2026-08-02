require "test_helper"

class GaugesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @location = create(:monitoring_location)
  end

  test "renders the canonical gauge page" do
    series = create(:time_series, monitoring_location: @location, parameter_code: "00065")
    LatestObservation.create!(
      time_series: series,
      value: 12.34,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    @location.update!(latest_water_level_value: 12.34, latest_water_level_unit: "ft", latest_water_level_parameter_code: "00065")

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, @location.name
    assert_includes response.body, "Gage height"
    assert_includes response.body, "role=\"tablist\""
    assert_includes response.headers["Cache-Tag"], "gauge:#{@location.site_number}"
  end

  test "renders state listing sorted by county then name" do
    create(:monitoring_location, site_number: "100", usgs_monitoring_location_id: "USGS-100", county_name: "Yakima", name: "Z River", state_code: "wa")
    create(:monitoring_location, site_number: "101", usgs_monitoring_location_id: "USGS-101", county_name: "Adams", name: "A Creek", state_code: "wa")

    get "/gauges/wa"
    assert_response :success
    assert_operator response.body.index("A Creek"), :<, response.body.index("Z River")
  end

  test "returns map stations for a bbox" do
    get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_kind_of Array, json["stations"]
  end
end
