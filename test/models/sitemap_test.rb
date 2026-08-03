require "test_helper"

class SitemapTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "index_xml lists static and every known state sitemap" do
    xml = Sitemap.index_xml(host: "example.com", protocol: "https")

    assert_includes xml, "<sitemapindex"
    assert_includes xml, "https://example.com/sitemaps/static.xml"
    Usgs::StateCodes::STATES.each_key do |code|
      assert_includes xml, "https://example.com/sitemaps/#{code}.xml"
    end
  end

  test "static_xml includes public pages and omits contact" do
    xml = Sitemap.static_xml(host: "example.com", protocol: "https")

    %w[/ /map /about /disclosures /faq /privacy /terms].each do |path|
      assert_includes xml, "<loc>https://example.com#{path}</loc>"
    end
    refute_includes xml, "/contact"
    refute_includes xml, "<lastmod>"
  end

  test "state_xml uses latest_observed_at for gauge and state lastmod" do
    older = create(
      :monitoring_location,
      site_number: "30000001",
      state_code: "wa",
      slug: "older-gauge",
      latest_observed_at: Time.utc(2026, 7, 1, 12, 0, 0)
    )
    newer = create(
      :monitoring_location,
      site_number: "30000002",
      state_code: "wa",
      slug: "newer-gauge",
      latest_observed_at: Time.utc(2026, 7, 15, 18, 30, 0)
    )

    xml = Sitemap.state_xml("wa", host: "example.com", protocol: "https")

    assert_includes xml, "<loc>https://example.com/gauges/wa</loc>"
    assert_includes xml, "<loc>https://example.com/gauges/wa/#{older.to_param}</loc>"
    assert_includes xml, "<loc>https://example.com/gauges/wa/#{newer.to_param}</loc>"
    assert_includes xml, "<lastmod>#{older.latest_observed_at.utc.xmlschema}</lastmod>"
    assert_includes xml, "<lastmod>#{newer.latest_observed_at.utc.xmlschema}</lastmod>"

    state_block = xml[%r{<url>\s*<loc>https://example.com/gauges/wa</loc>.*?</url>}m]
    assert state_block
    assert_includes state_block, "<lastmod>#{newer.latest_observed_at.utc.xmlschema}</lastmod>"
  end

  test "state_xml omits lastmod when latest_observed_at is nil" do
    create(
      :monitoring_location,
      site_number: "30000003",
      state_code: "or",
      slug: "no-obs",
      latest_observed_at: nil
    )

    xml = Sitemap.state_xml("or", host: "example.com", protocol: "https")

    assert_includes xml, "<loc>https://example.com/gauges/or/30000003-no-obs</loc>"
    refute_includes xml, "<lastmod>"
  end

  test "caches generated xml in Rails.cache" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    Sitemap.static_xml(host: "example.com", protocol: "https")
    assert Rails.cache.read(Sitemap.key_for("static")).present?
  ensure
    Rails.cache = previous
  end
end
