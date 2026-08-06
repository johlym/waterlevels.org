require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "renders the homepage with stats and popular regions" do
    create(
      :monitoring_location,
      site_number: "09380000",
      usgs_monitoring_location_id: "USGS-09380000",
      name: "COLORADO RIVER AT LEES FERRY, AZ",
      state_code: "az",
      state_name: "Arizona",
      flood_category: "action",
      nwps_matched: true
    )

    get root_path
    assert_response :success
    assert_includes response.body, "Monitor water levels"
    assert_includes response.body, "Active stations"
    assert_includes response.body, "Live data from"
    assert_includes response.body, "Total measurements"
    assert_includes response.body, "Updates today"
    assert_includes response.body, "Flood alerts"
    assert_includes response.body, 'class="value alert">1</p>'
    assert_includes response.body, 'href="/alerts"'

    assert_includes response.body, "Colorado River"
    assert_includes response.body, "Mississippi Basin"
    assert_includes response.body, "Great Lakes"
    assert_includes response.body, "Pacific Northwest"
    assert_includes response.body, "Colorado River At Lees Ferry, AZ"
    assert_includes response.body, "View Arizona stations"
    assert_includes response.body, "/gauges/az"
    assert_includes response.body, 'class="search-stack"'
    assert_includes response.body, 'data-controller="station-search"'
    assert_includes response.body, 'data-station-search-dialog-outlet="#home-geolocation-dialog"'
    assert_includes response.body, 'id="home-geolocation-dialog"'
    assert_includes response.body, 'data-controller="dialog"'
    assert_includes response.body, "Couldn’t get your location"
    assert_includes response.headers["Cache-Tag"], "home"
    assert_includes response.headers["Cache-Control"], "s-maxage=3600"
    assert_not_includes response.headers["Cache-Control"], "stale-while-revalidate"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "max-age=3600"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "stale-while-revalidate=86400"
    assert_includes response.body, 'name="turbo-cache-control" content="no-cache"'
  end

  test "map lives at /map without the site footer" do
    get map_path
    assert_response :success
    assert_includes response.body, 'data-controller="map"'
    assert_includes response.body, 'data-map-dialog-outlet="#map-geolocation-dialog"'
    assert_includes response.body, 'id="map-geolocation-dialog"'
    assert_includes response.body, 'data-controller="dialog"'
    assert_includes response.body, "map-mobile-search"
    assert_includes response.body, "Map settings"
    assert_includes response.body, '<details class="map-legend">'
    assert_includes response.body, "Flood stage"
    assert_includes response.body, "Station status"
    assert_not_includes response.body, "At / above flood stage"
    assert_not_includes response.body, 'data-map-target="floodCount"'
    assert_not_includes response.body, 'class="site-footer"'
    assert_includes response.headers["Cache-Tag"], "map"
    assert_not_includes response.headers["Cache-Control"], "stale-while-revalidate"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "stale-while-revalidate=86400"
    assert_includes response.body, 'name="turbo-cache-control" content="no-cache"'
  end
end
