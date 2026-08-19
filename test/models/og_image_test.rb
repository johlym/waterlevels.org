require "test_helper"

class OgImageTest < ActiveSupport::TestCase
  test "default svg includes brand and tagline" do
    svg = OgImage.new(:default).svg

    assert_includes svg, "WaterLevels.org"
    assert_includes svg, "Monitor water levels"
    assert_includes svg, "in real-time"
    assert_includes svg, "#09090b"
    assert_includes svg, "#22d3ee"
  end

  test "station svg includes name, site id, and measurements" do
    snapshot = {
      site_number: "99000099",
      name: "UPPER JADE IRIS ALDER CREEK NEAR SITE 99",
      state_code: "wa",
      stale: false,
      flood_category: "major",
      flood_category_label: "Major Flood",
      latest_observed_at: Time.utc(2026, 8, 3, 12, 0, 0).iso8601,
      measurements: [
        { kind: "water_level", label: "Gage height", value: 14.5, unit: "ft", precision: 2 },
        { kind: "discharge", label: "Flow", value: 1240, unit: "ft3/s", precision: 0 },
        { kind: "temperature", label: "Temperature", value: 12.0, unit: "°C", precision: 2 }
      ]
    }

    svg = OgImage.new(:station, snapshot: snapshot).svg

    assert_includes svg, "Upper Jade Iris Alder Creek Near Site 99"
    assert_includes svg, "Site 99000099"
    assert_includes svg, "Gage height"
    assert_includes svg, "14.50"
    assert_includes svg, "Flow"
    assert_includes svg, "1,240"
    assert_includes svg, "ft³/s"
    assert_includes svg, "Temperature"
    assert_includes svg, "53.6"
    assert_includes svg, "°F"
    assert_includes svg, "Major Flood"
    assert_includes svg, "Active"
  end

  test "default png renders via rsvg-convert" do
    skip "rsvg-convert not installed" unless rsvg_available?

    png = OgImage.default_png
    assert png.start_with?("\x89PNG".b)
    assert png.bytesize > 10_000
  end

  test "station png renders via rsvg-convert" do
    skip "rsvg-convert not installed" unless rsvg_available?

    snapshot = {
      site_number: "12345678",
      name: "Example River near Town",
      state_code: "wa",
      stale: false,
      flood_category: nil,
      latest_observed_at: Time.current.iso8601,
      measurements: [
        { kind: "water_level", label: "Gage height", value: 8.25, unit: "ft", precision: 2 }
      ]
    }

    png = OgImage.station_png(snapshot)
    assert png.start_with?("\x89PNG".b)
    assert png.bytesize > 10_000
  end

  test "station png is not written to Rails.cache when tips change" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    leftover = "#{OgImage::STATION_CACHE_PREFIX}:deadbeef"
    Rails.cache.write(leftover, "stale-png", expires_in: 24.hours)

    rasterizer = OgImage::Rasterizer.singleton_class
    original = rasterizer.instance_method(:to_png)
    rasterizer.define_method(:to_png) { |_svg| "FAKEPNG" }
    begin
      OgImage.station_png(station_snapshot(observed_at: "2026-08-19T11:00:00Z", value: 8.0))
      OgImage.station_png(station_snapshot(observed_at: "2026-08-19T12:00:00Z", value: 9.0))
    ensure
      rasterizer.define_method(:to_png, original)
    end

    cached_station_keys = memory_store_keys.grep(/og_image:v1:station/)
    assert Rails.cache.exist?(leftover)
    assert_equal 1, cached_station_keys.size
  ensure
    Rails.cache = previous
  end

  test "clear! drops leftover hashed station OG keys" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(OgImage::DEFAULT_CACHE_KEY, "default-png", expires_in: 24.hours)
    leftover = "#{OgImage::STATION_CACHE_PREFIX}:#{'a' * 64}"
    Rails.cache.write(leftover, "stale-png", expires_in: 24.hours)

    OgImage.clear!

    assert_not Rails.cache.exist?(OgImage::DEFAULT_CACHE_KEY)
    assert_not Rails.cache.exist?(leftover)
  ensure
    Rails.cache = previous
  end

  private

  def station_snapshot(observed_at:, value:)
    {
      site_number: "12345678",
      name: "Example River near Town",
      state_code: "wa",
      stale: false,
      flood_category: nil,
      latest_observed_at: observed_at,
      measurements: [
        { kind: "water_level", label: "Gage height", value: value, unit: "ft", precision: 2 }
      ]
    }
  end

  def memory_store_keys
    store = Rails.cache.instance_variable_get(:@data) || {}
    store.keys.map(&:to_s)
  end

  def rsvg_available?
    system("which", "rsvg-convert", out: File::NULL, err: File::NULL)
  end
end
