require "test_helper"

class StationSnapshotCacheTest < ActiveSupport::TestCase
  test "warm_stale_batch skips fresh snapshots" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    LatestObservation.create!(
      time_series: series,
      value: 10.0,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    StationSnapshotCache.warm(location.reload)

    warmed = StationSnapshotCache.warm_stale_batch
    assert_equal 0, warmed
  ensure
    Rails.cache = previous
  end
end
