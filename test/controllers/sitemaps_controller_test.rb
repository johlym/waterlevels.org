require "test_helper"

class SitemapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "index lists static and state child sitemaps with public cache headers" do
    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "/sitemaps/static.xml"
    assert_includes response.body, "/sitemaps/wa.xml"
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "s-maxage=86400"
    assert_equal "sitemap", response.headers["Cache-Tag"]
  end

  test "static sitemap includes public pages" do
    get "/sitemaps/static.xml"

    assert_response :success
    assert_includes response.body, "<loc>http://www.example.com/</loc>"
    assert_includes response.body, "<loc>http://www.example.com/about</loc>"
    refute_includes response.body, "/contact"
    assert_includes response.headers["Cache-Tag"], "sitemap:static"
  end

  test "state sitemap includes state page and gauges" do
    location = create(
      :monitoring_location,
      site_number: "40000001",
      state_code: "wa",
      slug: "green-river",
      latest_observed_at: Time.utc(2026, 6, 1, 9, 0, 0)
    )

    get "/sitemaps/wa.xml"

    assert_response :success
    assert_includes response.body, "<loc>http://www.example.com/gauges/wa</loc>"
    assert_includes response.body, "<loc>http://www.example.com/gauges/wa/#{location.to_param}</loc>"
    assert_includes response.body, "<lastmod>#{location.latest_observed_at.utc.xmlschema}</lastmod>"
    assert_includes response.headers["Cache-Tag"], "sitemap:state:wa"
  end

  test "unknown state returns not found" do
    get "/sitemaps/xx.xml"

    assert_response :not_found
  end
end
