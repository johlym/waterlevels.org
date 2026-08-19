require "test_helper"

class ApiCatalogTest < ActiveSupport::TestCase
  test "linkset lists site docs and upstream data APIs" do
    payload = ApiCatalog.linkset(base_url: "https://waterlevels.org")

    anchors = payload["linkset"].map { |entry| entry["anchor"] }
    assert_includes anchors, "https://waterlevels.org/"
    assert_includes anchors, ApiCatalog::USGS_API
    assert_includes anchors, ApiCatalog::NWPS_API

    serialized = payload.to_json
    refute_includes serialized, "https://waterlevels.org/api"
    refute_includes serialized, "/api/"
  end

  test "discovery link header uses registered relation types" do
    header = ApiCatalog.discovery_link_header

    assert_includes header, 'rel="api-catalog"'
    assert_includes header, 'rel="service-doc"'
    assert_includes header, 'rel="describedby"'
  end
end
