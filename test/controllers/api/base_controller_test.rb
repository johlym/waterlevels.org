require "test_helper"

class Api::BaseControllerTest < ActionDispatch::IntegrationTest
  setup do
    @location = create(
      :monitoring_location,
      latitude: 47.5,
      longitude: -121.8,
      state_code: "wa"
    )
  end

  test "forbids anonymous map station requests" do
    get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :forbidden
  end

  test "forbids map station requests with only the client header" do
    get "/api/map/stations",
      params: { bbox: "-125,45,-120,49" },
      headers: { "X-WaterLevels-Client" => "web" }
    assert_response :forbidden
  end

  test "allows first-party map station requests and keeps CDN cache headers" do
    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "s-maxage=300"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "max-age=300"
    assert_includes response.headers["Cache-Tag"], "map-stations"
    assert_includes response.headers["Vary"], "X-WaterLevels-Client"
    assert_includes response.headers["Vary"], "Sec-Fetch-Site"
  end

  test "forbids anonymous gauge observation requests" do
    get "/api/gauges/#{@location.site_number}/observations"
    assert_response :forbidden
  end

  test "allows first-party gauge observation requests" do
    api_get "/api/gauges/#{@location.site_number}/observations"
    assert_response :success
    assert_includes response.headers["Cache-Tag"], "gauge:#{@location.site_number}"
    assert_includes response.headers["Vary"], "X-WaterLevels-Client"
  end
end
