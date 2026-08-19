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
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @purger = FakePurger.new
    @invalidation = EdgeCacheInvalidation.new(purger: @purger)
    EdgeCachePurgeBuffer.backend = EdgeCachePurgeBuffer::MemoryBackend.new
    clear_enqueued_jobs
  end

  teardown do
    EdgeCachePurgeBuffer.reset!
    Rails.cache = @previous_cache
  end

  test "national latest sync purges aggregate surface tags and invalidates API Redis cache" do
    map_calls = 0
    ApiResponseCache.fetch_map_stations("-1,2,-3,4") do
      map_calls += 1
      { stations: [] }
    end

    @invalidation.after_latest_sync!(state: nil)
    tags = @purger.calls.first
    assert_includes tags, "home"
    assert_includes tags, "map"
    assert_includes tags, "alerts"
    assert_includes tags, "gauges"
    assert_includes tags, "states"
    assert_includes tags, "og"
    assert_not_includes tags, "map-stations"
    assert_not tags.any? { |tag| tag.start_with?("gauge:") }

    ApiResponseCache.fetch_map_stations("-1,2,-3,4") do
      map_calls += 1
      { stations: [ { id: "fresh" } ] }
    end
    assert_equal 2, map_calls
  end

  test "state-scoped latest sync purges that state's gauges" do
    create(:monitoring_location, site_number: "12101000", state_code: "wa")
    create(:monitoring_location, site_number: "09380000", state_code: "az")

    @invalidation.after_latest_sync!(state: "wa")
    tags = @purger.calls.first
    assert_includes tags, "state:wa"
    assert_includes tags, "og"
    assert_includes tags, "gauge:12101000"
    assert_not_includes tags, "gauge:09380000"
  end

  test "station history queues gauge, state, and shared map tags for a deferred flush" do
    location = create(:monitoring_location, site_number: "12101000", state_code: "wa")
    obs_calls = 0
    ApiResponseCache.fetch_observations(
      site_number: location.site_number,
      parameter_code: "00065",
      kind: "water_level",
      range: "7d"
    ) do
      obs_calls += 1
      { points: [ 1 ] }
    end

    assert_enqueued_with(job: EdgeCachePurgeJob) do
      assert_equal :queued, @invalidation.after_station_history!(location)
    end

    assert_empty @purger.calls

    assert_equal :purged, EdgeCacheInvalidation.flush_pending!(purger: @purger)
    tags = @purger.calls.first
    assert_includes tags, "gauge:12101000"
    assert_includes tags, "gauges"
    assert_includes tags, "state:wa"
    assert_includes tags, "map"
    assert_not_includes tags, "map-stations"

    ApiResponseCache.fetch_observations(
      site_number: location.site_number,
      parameter_code: "00065",
      kind: "water_level",
      range: "7d"
    ) do
      obs_calls += 1
      { points: [ 2 ] }
    end
    assert_equal 2, obs_calls
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
