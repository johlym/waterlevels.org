require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "renders the homepage with stats and popular regions" do
    create(
      :monitoring_location,
      site_number: "09380000",
      usgs_monitoring_location_id: "USGS-09380000",
      name: "COLORADO RIVER AT LEES FERRY, AZ",
      state_code: "az",
      state_name: "Arizona"
    )

    get root_path
    assert_response :success
    assert_includes response.body, "Monitor water levels"
    assert_includes response.body, "Total stations"
    assert_includes response.body, "Total measurements"
    assert_includes response.body, "Updates per hour"
    assert_includes response.body, "Colorado River"
    assert_includes response.body, "Mississippi Basin"
    assert_includes response.body, "Great Lakes"
    assert_includes response.body, "Pacific Northwest"
    assert_includes response.body, "Colorado River At Lees Ferry, AZ"
    assert_includes response.body, 'data-controller="station-search"'
    assert_includes response.headers["Cache-Tag"], "home"
  end

  test "map lives at /map without the site footer" do
    get map_path
    assert_response :success
    assert_includes response.body, 'data-controller="map"'
    assert_includes response.body, "map-mobile-search"
    assert_includes response.body, "Map settings"
    assert_not_includes response.body, 'class="site-footer"'
    assert_includes response.headers["Cache-Tag"], "map"
  end
end
