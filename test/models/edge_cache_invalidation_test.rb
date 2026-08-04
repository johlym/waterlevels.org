require "test_helper"

class EdgeCacheInvalidationTest < ActiveSupport::TestCase
  class FakePurger
    attr_reader :calls

    def initialize
      @calls = []
    end

    def purge_tags(tags)
      @calls << Array(tags)
      :purged
    end
  end

  setup do
    @purger = FakePurger.new
    @invalidation = EdgeCacheInvalidation.new(purger: @purger)
  end

  test "national latest sync purges aggregate surface tags" do
    @invalidation.after_latest_sync!(state: nil)
    tags = @purger.calls.first
    assert_includes tags, "home"
    assert_includes tags, "map"
    assert_includes tags, "alerts"
    assert_includes tags, "gauges"
    assert_includes tags, "states"
    assert_includes tags, "map-stations"
    assert_not tags.any? { |tag| tag.start_with?("gauge:") }
  end

  test "state-scoped latest sync purges that state's gauges" do
    create(:monitoring_location, site_number: "12101000", state_code: "wa")
    create(:monitoring_location, site_number: "09380000", state_code: "az")

    @invalidation.after_latest_sync!(state: "wa")
    tags = @purger.calls.first
    assert_includes tags, "state:wa"
    assert_includes tags, "gauge:12101000"
    assert_not_includes tags, "gauge:09380000"
  end

  test "station history purges gauge and state tags" do
    location = create(:monitoring_location, site_number: "12101000", state_code: "wa")
    @invalidation.after_station_history!(location)
    tags = @purger.calls.first
    assert_includes tags, "gauge:12101000"
    assert_includes tags, "gauges"
    assert_includes tags, "state:wa"
  end

  test "catalog sync also purges sitemap" do
    @invalidation.after_catalog_sync!(state: nil)
    assert_includes @purger.calls.first, "sitemap"
  end
end
