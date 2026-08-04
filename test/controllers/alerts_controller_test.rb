require "test_helper"

class AlertsControllerTest < ActionDispatch::IntegrationTest
  test "renders alerts page grouped by state with only alert stations" do
    create(
      :monitoring_location,
      site_number: "300",
      usgs_monitoring_location_id: "USGS-300",
      county_name: "King",
      name: "FLOOD CREEK NEAR TOWN, WA",
      state_code: "wa",
      state_name: "Washington",
      flood_category: "action",
      nwps_matched: true,
      latest_water_level_value: 6.2,
      latest_water_level_unit: "ft",
      latest_observed_at: 30.minutes.ago
    )
    create(
      :monitoring_location,
      site_number: "301",
      usgs_monitoring_location_id: "USGS-301",
      county_name: "Travis",
      name: "MAJOR RIVER NEAR CITY, TX",
      state_code: "tx",
      state_name: "Texas",
      flood_category: "major",
      nwps_matched: true,
      latest_water_level_value: 15.0,
      latest_water_level_unit: "ft",
      latest_observed_at: 20.minutes.ago
    )
    create(
      :monitoring_location,
      site_number: "302",
      usgs_monitoring_location_id: "USGS-302",
      county_name: "King",
      name: "QUIET CREEK NEAR TOWN, WA",
      state_code: "wa",
      state_name: "Washington",
      flood_category: "no_flooding"
    )

    get alerts_path
    assert_response :success
    assert_includes response.body, "Stations With Active Alerts"
    assert_includes response.body, "Alert Stations"
    assert_includes response.body, "States Affected"
    assert_includes response.body, "Major Flooding"
    assert_includes response.body, "Washington"
    assert_includes response.body, "Texas"
    assert_includes response.body, "Flood Creek Near Town, WA"
    assert_includes response.body, "Major River Near City, TX"
    assert_not_includes response.body, "Quiet Creek Near Town, WA"
    assert_includes response.body, "Quick state jump"
    assert_not_includes response.body, "Quick county jump"
    assert_not_includes response.body, "Stations with alerts"
    assert_not_includes response.body, 'data-state-directory-target="alertsOnly"'
    assert_operator response.body.index("Texas"), :<, response.body.index("Washington")
    assert_includes response.headers["Cache-Tag"], "alerts"
    assert_includes response.headers["Cache-Control"], "s-maxage=3600"
    assert_not_includes response.headers["Cache-Control"], "stale-while-revalidate"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "stale-while-revalidate=86400"
  end

  test "renders empty state when no stations have alerts" do
    create(
      :monitoring_location,
      site_number: "303",
      usgs_monitoring_location_id: "USGS-303",
      name: "QUIET CREEK NEAR TOWN, WA",
      state_code: "wa",
      flood_category: "no_flooding"
    )

    get alerts_path
    assert_response :success
    assert_includes response.body, "No stations currently have flood alerts"
    assert_not_includes response.body, "Quiet Creek Near Town, WA"
  end
end
