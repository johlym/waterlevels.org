require "test_helper"

class StationSnapshotCacheTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "payload includes agency credit for non-USGS reporters" do
    location = create(:monitoring_location)
    location.update!(
      agency_code: "TX071",
      agency_name: "Lower Colorado River Authority, TX",
      usgs_monitoring_location_id: "TX071-#{location.site_number}"
    )

    payload = StationSnapshotCache.warm(location.reload)
    assert_equal "TX071", payload[:agency_code]
    assert_equal "Lower Colorado River Authority, TX", payload[:agency_name]
    assert_equal "Lower Colorado River Authority", payload[:agency_credit]
  end

  test "payload omits agency credit for USGS sites" do
    location = create(:monitoring_location, agency_code: "USGS", agency_name: "U.S. Geological Survey")

    payload = StationSnapshotCache.warm(location)
    assert_equal "USGS", payload[:agency_code]
    assert_nil payload[:agency_credit]
  end

  test "warm_stale_batch skips fresh snapshots" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    LatestObservation.create!(
      time_series: series,
      value: 10.0,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    location.update!(latest_observed_at: series.latest_observation.observed_at)
    StationSnapshotCache.warm(location.reload)

    warmed = StationSnapshotCache.warm_stale_batch
    assert_equal 0, warmed
  end

  test "latest_observed_at uses the newest measurement datapoint even when location column lags" do
    older = Time.utc(2026, 8, 2, 12, 0, 0)
    newer = Time.utc(2026, 8, 2, 18, 0, 0)
    location = create(:monitoring_location, latest_observed_at: older)

    water_level = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true,
      usgs_time_series_id: "ts-wl-lag"
    )
    discharge = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      selected_for_display: true,
      usgs_time_series_id: "ts-q-lag"
    )
    LatestObservation.create!(
      time_series: water_level,
      value: 4.2,
      unit_of_measure: "ft",
      observed_at: older,
      synced_at: Time.current
    )
    LatestObservation.create!(
      time_series: discharge,
      value: 1200,
      unit_of_measure: "ft3/s",
      observed_at: newer,
      synced_at: Time.current
    )

    payload = StationSnapshotCache.warm(location.reload)
    assert_equal newer.iso8601, payload[:latest_observed_at]
    assert_equal 2, payload[:measurements].size
  end

  test "fetch rebuilds when a newer datapoint arrives for an existing measurement" do
    older = Time.utc(2026, 8, 2, 12, 0, 0)
    newer = Time.utc(2026, 8, 2, 15, 30, 0)
    location = create(:monitoring_location, latest_observed_at: older)
    series = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    observation = LatestObservation.create!(
      time_series: series,
      value: 3.0,
      unit_of_measure: "ft",
      observed_at: older,
      synced_at: Time.current
    )
    StationSnapshotCache.warm(location.reload)

    observation.update!(value: 3.5, observed_at: newer)
    # Denormalized column still lagging behind the collected tip.
    location.update!(latest_observed_at: older)

    payload = StationSnapshotCache.fetch(location.reload)
    assert_equal newer.iso8601, payload[:latest_observed_at]
    assert_in_delta 3.5, payload[:measurements].first[:value], 0.001
  end

  test "nearby payload includes all available measurements for a neighbor" do
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
    origin.update!(nearby_station_ids: [ neighbor.id ])

    payload = StationSnapshotCache.warm(origin.reload)
    nearby = payload[:nearby]
    assert_equal 1, nearby.size

    readings = nearby.first[:measurements]
    assert_equal %w[ discharge water_level temperature ], readings.map { |r| r[:kind] }
    assert_equal 1250.0, readings[0][:value]
    assert_equal 4.25, readings[1][:value]
    assert_equal 12.8, readings[2][:value]
  end
end
