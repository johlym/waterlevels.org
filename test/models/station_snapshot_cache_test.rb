require "test_helper"

class StationSnapshotCacheTest < ActiveSupport::TestCase
  setup do
    @location = create(
      :monitoring_location,
      latest_water_level_value: 541.24,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      has_water_level: true,
      has_discharge: false
    )
    gage = create(:time_series, monitoring_location: @location, parameter_code: "00065", measurement_kind: "water_level", usgs_time_series_id: "ts-gage")
    ngvd = create(:time_series, monitoring_location: @location, parameter_code: "62614", measurement_kind: "water_level", usgs_time_series_id: "ts-ngvd")
    LatestObservation.create!(
      time_series: gage,
      value: 541.24,
      unit_of_measure: "ft",
      observed_at: Time.utc(2026, 8, 2, 4, 30),
      approval_status: "Provisional",
      synced_at: Time.current
    )
    LatestObservation.create!(
      time_series: ngvd,
      value: 540.74,
      unit_of_measure: "ft",
      observed_at: Time.utc(2026, 8, 2, 4, 30),
      approval_status: "Provisional",
      synced_at: Time.current
    )
    Rails.cache.clear
  end

  test "fetch rebuilds when cached snapshot has empty current but location has readings" do
    Rails.cache.write(
      StationSnapshotCache.key_for(@location),
      {
        site_number: @location.site_number,
        name: @location.name,
        state_code: @location.state_code,
        measurement_kinds: [],
        measurements: [],
        current: {},
        trends: {},
        extremes: {},
        nearby: []
      },
      expires_in: 2.hours
    )

    snapshot = StationSnapshotCache.fetch(@location)

    assert_equal 541.24, snapshot[:measurements].first[:value]
    assert_equal "Gage height", snapshot[:measurements].first[:label]
  end

  test "fetch rebuilds when cache has fewer measurements than selected series" do
    Rails.cache.write(
      StationSnapshotCache.key_for(@location),
      {
        site_number: @location.site_number,
        measurements: [ { parameter_code: "00065", label: "Gage height", value: 541.24, kind: "water_level" } ],
        current: { "water_level" => { value: 541.24 } }
      },
      expires_in: 2.hours
    )

    snapshot = StationSnapshotCache.fetch(@location)

    assert_equal 2, snapshot[:measurements].size
    assert_equal [ "00065", "62614" ], snapshot[:measurements].map { |m| m[:parameter_code] }
  end

  test "build_payload includes both gage height and NGVD measurements with gage first" do
    snapshot = StationSnapshotCache.build_payload(@location.reload)
    labels = snapshot[:measurements].map { |m| m[:label] }

    assert_equal [ "Gage height", "Elevation (NGVD 1929)" ], labels
    assert_equal "00065", snapshot[:measurements].first[:parameter_code]
  end

  test "build_payload falls back to denormalized location values" do
    @location.time_series.destroy_all
    @location.update!(has_water_level: true, latest_water_level_value: 12.5, latest_water_level_unit: "ft", latest_water_level_parameter_code: "00065")

    snapshot = StationSnapshotCache.build_payload(@location.reload)

    assert_equal 12.5, snapshot[:measurements].first[:value]
    assert_equal "Gage height", snapshot[:measurements].first[:label]
  end

  test "build_payload includes nearby distance and primary reading" do
    nearby = create(
      :monitoring_location,
      site_number: "99999001",
      usgs_monitoring_location_id: "usgs-99999001",
      latitude: @location.latitude.to_f + 0.05,
      longitude: @location.longitude,
      latest_discharge_value: 120,
      latest_discharge_unit: "ft3/s",
      has_discharge: true,
      latest_observed_at: Time.current
    )
    @location.update!(nearby_station_ids: [ nearby.id ])

    snapshot = StationSnapshotCache.build_payload(@location.reload)
    card = snapshot[:nearby].first

    assert_equal nearby.site_number, card[:site_number]
    assert card[:distance_mi].positive?
    assert_equal false, card[:stale]
    assert_equal "Flow", card[:primary][:label]
    assert_equal 120.0, card[:primary][:value]
  end
end
