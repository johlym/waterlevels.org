require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  %w[about disclosures faq privacy terms].each do |page|
    test "renders #{page}" do
      get "/#{page}"
      assert_response :success
      assert_includes response.headers["Cache-Control"], "public"
    end
  end

  test "disclosures page attributes USGS and NWS flood data" do
    get disclosures_path
    assert_response :success
    assert_includes response.body, "USGS &amp; NWS data"
    assert_includes response.body, "National Water Prediction Service"
    assert_includes response.body, "https://water.noaa.gov/"
    assert_includes response.body, "https://api.water.noaa.gov/nwps/v1/docs/"
    assert_includes response.body, "Flood categories and stage thresholds"
    assert_includes response.body, "NWS flood context"
  end

  test "404s unknown pages" do
    get "/pages/nope"
    assert_response :not_found
  end
end
