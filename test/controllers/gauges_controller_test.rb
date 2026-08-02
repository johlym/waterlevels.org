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
    assert_includes response.body, "Example River Near Town"
    assert_includes response.body, "Gage height"
    assert_includes response.body, "role=\"tablist\""
    assert_includes response.body, ">King<"
    assert_not_includes response.body, "King County"
    assert_includes response.headers["Cache-Tag"], "gauge:#{@location.site_number}"
  end

  test "renders state listing grouped by county with titlecased locations" do
    create(:monitoring_location, site_number: "100", usgs_monitoring_location_id: "USGS-100", county_name: "Yakima", name: "Z RIVER NEAR TOWN, WA", state_code: "wa")
    create(:monitoring_location, site_number: "101", usgs_monitoring_location_id: "USGS-101", county_name: "Adams", name: "A CREEK NEAR TOWN, WA", state_code: "wa")

    get "/gauges/wa"
    assert_response :success
    assert_includes response.body, "Adams"
    assert_includes response.body, "Yakima"
    assert_includes response.body, "A Creek Near Town, WA"
    assert_includes response.body, "Z River Near Town, WA"
    assert_operator response.body.index("Adams"), :<, response.body.index("Yakima")
    assert_operator response.body.index("A Creek Near Town, WA"), :<, response.body.index("Z River Near Town, WA")
  end

  test "returns map stations for a bbox" do
    get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_kind_of Array, json["stations"]
  end
end
