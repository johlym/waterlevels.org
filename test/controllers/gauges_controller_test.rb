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
      observed_at: Time.utc(2026, 8, 2, 4, 30, 0),
      synced_at: Time.current
    )
    @location.update!(
      latest_water_level_value: 12.34,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_observed_at: Time.utc(2026, 8, 2, 4, 30, 0),
      time_zone: "PST"
    )

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Example River Near Town"
    assert_includes response.body, "Gage height"
    assert_includes response.body, "role=\"tablist\""
    assert_includes response.body, ">King<"
    assert_not_includes response.body, "King County"
    assert_includes response.body, "August 1, 2026 at 09:30:00 PM PDT"
    assert_includes response.body, 'data-hydrograph-time-zone-value="America/Los_Angeles"'
    assert_includes response.body, 'data-hydrograph-time-zone-label-value="PST"'
    assert_includes response.headers["Cache-Tag"], "gauge:#{@location.site_number}"
  end

  test "nearby stations show all available measurements" do
    neighbor = create(
      :monitoring_location,
      site_number: "00000999",
      usgs_monitoring_location_id: "USGS-00000999",
      name: "Neighbor Creek near Town",
      slug: "neighbor-creek-near-town",
      latitude: 47.51,
      longitude: -121.81,
      has_water_level: true,
      has_discharge: true,
      has_temperature: true,
      latest_discharge_value: 1250.0,
      latest_discharge_unit: "ft3/s",
      latest_water_level_value: 4.25,
      latest_water_level_unit: "ft",
      latest_temperature_c: 12.8,
      latest_observed_at: 30.minutes.ago
    )
    @location.update!(nearby_station_ids: [ neighbor.id ])

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Nearby stations"
    assert_includes response.body, "Neighbor Creek Near Town"
    assert_includes response.body, "Flow:"
    assert_includes response.body, "1,250"
    assert_includes response.body, "Level:"
    assert_includes response.body, "4.25"
    assert_includes response.body, 'data-temp-prefix="Temp: "'
    assert_includes response.body, 'data-temp-c="12.8"'
  end

  test "map stations include station time zone fields" do
    @location.update!(time_zone: "CST", state_code: "tx", state_name: "Texas", latitude: 30.27, longitude: -97.74)

    get "/api/map/stations", params: { bbox: "-98,30,-97,31" }
    assert_response :success
    station = JSON.parse(response.body)["stations"].find { |row| row["id"] == @location.site_number }
    assert_equal "CST", station["time_zone"]
    assert_equal "America/Chicago", station["time_zone_identifier"]
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

  test "searches all monitoring locations without a bbox" do
    in_view = create(
      :monitoring_location,
      site_number: "12101000",
      usgs_monitoring_location_id: "USGS-12101000",
      name: "SNOHOMISH RIVER NEAR MONROE, WA",
      latitude: 47.85,
      longitude: -122.0,
      state_code: "wa"
    )
    out_of_view = create(
      :monitoring_location,
      site_number: "01646500",
      usgs_monitoring_location_id: "USGS-01646500",
      name: "POTOMAC RIVER NEAR WASH, DC",
      latitude: 38.95,
      longitude: -77.13,
      state_code: "md"
    )

    get "/api/map/stations/search", params: { q: "potomac" }
    assert_response :success
    stations = JSON.parse(response.body)["stations"]
    ids = stations.map { |row| row["id"] }

    assert_includes ids, out_of_view.site_number
    assert_not_includes ids, in_view.site_number
    assert_equal "/gauges/md/#{out_of_view.to_param}", stations.first["path"]
    assert_not stations.first.key?("lat")
  end

  test "station search requires at least two characters" do
    create(:monitoring_location, name: "POTOMAC RIVER NEAR WASH, DC", state_code: "md")

    get "/api/map/stations/search", params: { q: "p" }
    assert_response :success
    assert_equal [], JSON.parse(response.body)["stations"]
  end

  test "nearest station returns the closest location path" do
    create(:monitoring_location, site_number: "20000001", latitude: 47.0, longitude: -122.0)
    near = create(:monitoring_location, site_number: "20000002", latitude: 47.05, longitude: -122.05)

    get "/api/map/stations/nearest", params: { lat: 47.051, lon: -122.051 }
    assert_response :success
    station = JSON.parse(response.body)["station"]
    assert_equal near.site_number, station["id"]
    assert_equal "/gauges/#{near.path_state}/#{near.to_param}", station["path"]
  end
end

