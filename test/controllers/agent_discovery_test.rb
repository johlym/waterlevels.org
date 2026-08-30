require "test_helper"

class AgentDiscoveryTest < ActionDispatch::IntegrationTest
  test "robots.txt declares content signals" do
    get "/robots.txt"

    assert_response :success
    assert_includes response.body, "Content-Signal: ai-train=no, search=yes, ai-input=no"
    assert_includes response.body, "Disallow: /admin"
    assert_includes response.body, "Disallow: /api"
    assert_includes response.body, "Sitemap: https://waterlevels.org/sitemap.xml"
  end

  test "llms.txt describes the site and points agents at USGS and NWPS" do
    get "/llms.txt"

    assert_response :success
    assert_includes response.body, "WaterLevels.org"
    assert_includes response.body, "does not offer a public third-party data API"
    assert_includes response.body, "https://api.waterdata.usgs.gov/"
    assert_includes response.body, "https://api.water.noaa.gov/nwps/v1/docs/"
    assert_includes response.body, "/.well-known/api-catalog"
    assert_includes response.body, "/aup"
  end
end
