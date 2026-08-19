require "test_helper"

class WellKnown::ApiCatalogControllerTest < ActionDispatch::IntegrationTest
  test "returns an RFC 9727 linkset and does not advertise first-party APIs" do
    get api_catalog_path

    assert_response :success
    assert_includes response.media_type, "application/linkset+json"
    assert_includes response.content_type, 'profile="https://www.rfc-editor.org/info/rfc9727"'
    assert_includes response.headers["Link"], 'rel="api-catalog"'
    assert_includes response.headers["Cache-Control"], "public"

    payload = JSON.parse(response.body)
    assert payload.key?("linkset")
    anchors = payload["linkset"].map { |entry| entry["anchor"] }
    assert_includes anchors, "http://www.example.com/"
    assert_includes anchors, ApiCatalog::USGS_API
    assert_includes anchors, ApiCatalog::NWPS_API
    refute_includes response.body, "/api/"
    refute_includes response.body, "#{request.base_url}/api"
  end

  test "HEAD includes the api-catalog link relation" do
    head api_catalog_path

    assert_response :success
    assert_includes response.headers["Link"], 'rel="api-catalog"'
    assert_includes response.media_type, "application/linkset+json"
  end
end
