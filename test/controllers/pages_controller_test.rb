require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  %w[about aup disclosures faq privacy terms].each do |page|
    test "renders #{page}" do
      get "/#{page}"
      assert_response :success
      assert_includes response.headers["Cache-Control"], "public"
    end
  end

  test "aup page publishes the current acceptable use policy" do
    get aup_path
    assert_response :success
    assert_includes response.body, "Acceptable Use Policy"
    assert_includes response.body, "Last reviewed August 30, 2026"
    assert_includes response.body, "Prohibited Activity"
    assert_includes response.body, "confirmed opt-in"
    assert_includes response.body, aup_path
  end

  test "privacy page publishes the current privacy policy" do
    get privacy_path
    assert_response :success
    assert_includes response.body, "Privacy Policy"
    assert_includes response.body, "August 30, 2026"
    assert_includes response.body, "Cloudflare"
    assert_includes response.body, "Fathom Analytics"
    assert_includes response.body, "Sentry"
    assert_includes response.body, "Bento"
    assert_includes response.body, "General Data Protection Regulation"
    assert_includes response.body, contact_path
  end

  test "terms page publishes the current terms and conditions" do
    get terms_path
    assert_response :success
    assert_includes response.body, "Terms and Conditions"
    assert_includes response.body, "Bytoro LLC"
    assert_includes response.body, "August 30, 2026"
    assert_includes response.body, "$100"
    refute_includes response.body, "mpkwali0-x9idrhsjr8a"
    assert_includes response.body, privacy_path
    assert_includes response.body, aup_path
    assert_includes response.body, contact_path
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

  test "faq page covers NWS flood data sources and alerts" do
    get faq_path
    assert_response :success
    assert_includes response.body, "What flood data do you show?"
    assert_includes response.body, "Why doesn’t every station have flood stages?"
    assert_includes response.body, "What is the flood alerts list?"
    assert_includes response.body, "Is this an official USGS or NWS website?"
    assert_includes response.body, "National Water Prediction Service"
    assert_includes response.body, "https://water.noaa.gov/"
    assert_includes response.body, "https://api.water.noaa.gov/nwps/v1/docs/"
    assert_includes response.body, 'id="flood-data"'
    assert_includes response.body, alerts_path
  end

  test "returns markdown for disclosures when agents request it" do
    get disclosures_path, headers: {
      "Accept" => "text/markdown",
      "User-Agent" => "curl/8.5.0"
    }

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "USGS"
    assert_includes response.body, "National Water Prediction Service"
    assert response.headers["x-markdown-tokens"].to_i.positive?
    assert_includes response.headers["Vary"], "Accept"
  end

  test "404s unknown pages" do
    get "/pages/nope"
    assert_response :not_found
  end
end
