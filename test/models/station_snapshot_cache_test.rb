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

  test "nearby payload includes all available measurements for a neighbor" do
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    origin = create(:monitoring_location, site_number: "00000001", usgs_monitoring_location_id: "USGS-00000001")
    neighbor = create(
      :monitoring_location,
      site_number: "00000002",
      usgs_monitoring_location_id: "USGS-00000002",
      name: "Neighbor Creek near Town",
      slug: "neighbor-creek-near-town",
      latitude: 47.51,
      longitude: -121.81,
      has_water_level: true,
      has_discharge: true,
      has_temperature: true,
      latest_discharge_value: 1250.0,
      latest_discharge_unit: "ft3/s",
      latest_water_level_value: 4.25,
      latest_water_level_unit: "ft",
      latest_temperature_c: 12.8,
      latest_observed_at: 30.minutes.ago
    )
    origin.update!(nearby_station_ids: [neighbor.id])

    payload = StationSnapshotCache.warm(origin.reload)
    nearby = payload[:nearby]
    assert_equal 1, nearby.size

    readings = nearby.first[:measurements]
    assert_equal %w[discharge water_level temperature], readings.map { |r| r[:kind] }
    assert_equal 1250.0, readings[0][:value]
    assert_equal 4.25, readings[1][:value]
    assert_equal 12.8, readings[2][:value]
  ensure
    Rails.cache = previous
  end
end
