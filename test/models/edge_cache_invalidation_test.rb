require "test_helper"

class EdgeCacheInvalidationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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
    EdgeCachePurgeBuffer.backend = EdgeCachePurgeBuffer::MemoryBackend.new
    clear_enqueued_jobs
  end

  teardown do
    EdgeCachePurgeBuffer.reset!
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

  test "station history queues gauge, state, and shared map tags for a deferred flush" do
    location = create(:monitoring_location, site_number: "12101000", state_code: "wa")

    assert_enqueued_with(job: EdgeCachePurgeJob) do
      assert_equal :queued, @invalidation.after_station_history!(location)
    end

    assert_empty @purger.calls

    assert_equal :purged, EdgeCacheInvalidation.flush_pending!(purger: @purger)
    tags = @purger.calls.first
    assert_includes tags, "gauge:12101000"
    assert_includes tags, "gauges"
    assert_includes tags, "state:wa"
    assert_includes tags, "map-stations"
    assert_includes tags, "map"
  end

  test "coalesce flushes history tags once across many stations" do
    a = create(:monitoring_location, site_number: "12101000", state_code: "wa")
    b = create(:monitoring_location, site_number: "12102000", state_code: "wa")

    assert_no_enqueued_jobs only: EdgeCachePurgeJob do
      EdgeCacheInvalidation.coalesce(purger: @purger) do
        EdgeCacheInvalidation.after_station_history!(a, purger: @purger)
        EdgeCacheInvalidation.after_station_history!(b, purger: @purger)
      end
    end

    assert_equal 1, @purger.calls.size
    tags = @purger.calls.first
    assert_includes tags, "gauge:12101000"
    assert_includes tags, "gauge:12102000"
    assert_equal 1, tags.count("gauges")
    assert_equal 1, tags.count("map")
  end

  test "repeated history queueing schedules a single flush job" do
    a = create(:monitoring_location, site_number: "12101000", state_code: "wa")
    b = create(:monitoring_location, site_number: "12102000", state_code: "wa")

    assert_enqueued_jobs 1, only: EdgeCachePurgeJob do
      EdgeCacheInvalidation.after_station_history!(a)
      EdgeCacheInvalidation.after_station_history!(b)
    end
  end

  test "catalog sync also purges sitemap" do
    @invalidation.after_catalog_sync!(state: nil)
    assert_includes @purger.calls.first, "sitemap"
  end
end
