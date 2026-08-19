require "test_helper"

class OgImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @location = create(
      :monitoring_location,
      latest_water_level_value: 12.34,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_discharge_value: 500,
      latest_discharge_unit: "ft3/s",
      latest_observed_at: Time.utc(2026, 8, 2, 4, 30, 0)
    )
  end

  test "default og image returns png" do
    skip "rsvg-convert not installed" unless rsvg_available?

    get og_default_path
    assert_response :success
    assert_equal "image/png", response.media_type
    assert response.body.start_with?("\x89PNG".b)
    assert_includes response.headers["Cache-Tag"], "og:default"
  end

  test "station og image returns png" do
    skip "rsvg-convert not installed" unless rsvg_available?

    get og_station_path(@location.site_number)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert response.body.start_with?("\x89PNG".b)
    assert_includes response.headers["Cache-Tag"], "og:gauge:#{@location.site_number}"
    assert_includes response.headers["Cache-Tag"], "og"
    assert_includes response.headers["Cache-Tag"], "gauges"
    assert_includes response.headers["Cache-Control"], "s-maxage=3600"
    assert_nil response.headers["Cloudflare-CDN-Cache-Control"]
  end

  test "station og image 404s for unknown site" do
    get og_station_path("00000000")
    assert_response :not_found
  end

  test "gauge page advertises station og image" do
    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "property=\"og:image\""
    assert_includes response.body, "/og/gauges/#{@location.site_number}.png"
    assert_includes response.body, "name=\"twitter:card\""
    assert_includes response.body, "summary_large_image"
  end

  test "home page advertises default og image" do
    get root_path
    assert_response :success
    assert_includes response.body, "property=\"og:image\""
    assert_includes response.body, "/og.png"
  end

  private

  def rsvg_available?
    system("which", "rsvg-convert", out: File::NULL, err: File::NULL)
  end
end
