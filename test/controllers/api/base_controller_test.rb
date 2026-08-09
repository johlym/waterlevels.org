require "test_helper"

class Api::BaseControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @location = create(
      :monitoring_location,
      latitude: 47.5,
      longitude: -121.8,
      state_code: "wa"
    )
  end

  teardown do
    Rails.cache = @previous_cache
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

  test "allows first-party map station requests with private no-store headers" do
    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    assert_includes response.headers["Cache-Control"], "private"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_nil response.headers["Cloudflare-CDN-Cache-Control"]
    assert_nil response.headers["Cache-Tag"]
  end

  test "serves map stations from Redis cache on repeat requests" do
    bbox = { bbox: "-125,45,-120,49" }
    api_get "/api/map/stations", params: bbox
    assert_response :success
    first_body = response.body

    @location.update!(name: "CHANGED NAME SHOULD NOT APPEAR UNTIL INVALIDATION")

    api_get "/api/map/stations", params: bbox
    assert_response :success
    assert_equal first_body, response.body
    assert_not_includes response.body, "CHANGED NAME SHOULD NOT APPEAR UNTIL INVALIDATION"

    ApiResponseCache.invalidate_map!

    api_get "/api/map/stations", params: bbox
    assert_response :success
    assert_includes response.body, "Changed Name Should Not Appear Until Invalidation"
  end

  test "forbids anonymous gauge observation requests" do
    get "/api/gauges/#{@location.site_number}/observations"
    assert_response :forbidden
  end

  test "allows first-party gauge observation requests with private no-store headers" do
    api_get "/api/gauges/#{@location.site_number}/observations"
    assert_response :success
    assert_includes response.headers["Cache-Control"], "private"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_nil response.headers["Cache-Tag"]
  end
end
