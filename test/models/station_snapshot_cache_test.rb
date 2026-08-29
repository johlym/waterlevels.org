require "test_helper"

class StationSnapshotCacheTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
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

  test "warm avoids per-series observation N+1 queries" do
    observed_at = Time.utc(2026, 8, 4, 18, 0, 0)
    location = create(:monitoring_location, latest_observed_at: observed_at)

    series_specs = [
      { parameter_code: "00065", measurement_kind: "water_level", unit: "ft", value: 4.5, usgs_time_series_id: "ts-wl-n1" },
      { parameter_code: "00060", measurement_kind: "discharge", unit: "ft3/s", value: 1200.0, usgs_time_series_id: "ts-q-n1" },
      { parameter_code: "00010", measurement_kind: "temperature", unit: "degC", value: 14.2, usgs_time_series_id: "ts-t-n1" }
    ]

    series_specs.each_with_index do |spec, index|
      series = create(
        :time_series,
        monitoring_location: location,
        parameter_code: spec[:parameter_code],
        measurement_kind: spec[:measurement_kind],
        selected_for_display: true,
        usgs_time_series_id: spec[:usgs_time_series_id],
        unit_of_measure: spec[:unit]
      )
      LatestObservation.create!(
        time_series: series,
        value: spec[:value],
        unit_of_measure: spec[:unit],
        observed_at: observed_at,
        synced_at: Time.current
      )
      ContinuousObservation.create!(
        time_series: series,
        value: spec[:value] - 1,
        observed_at: observed_at - 25.hours
      )
      DailyObservation.create!(
        time_series: series,
        value: spec[:value] - 2,
        observed_on: observed_at.to_date - 1.year
      )
      DailyObservation.create!(
        time_series: series,
        value: spec[:value] - 3,
        observed_on: observed_at.to_date - 2.days
      )
      PeakObservation.create!(
        time_series: series,
        peak_kind: "high",
        water_year: 2025 + index,
        value: spec[:value] + 10,
        observed_at: observed_at - 30.days
      )
    end

    sql = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if payload[:name] == "SCHEMA"
      sql << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      payload = StationSnapshotCache.warm(location.reload)
      assert_equal 3, payload[:measurements].size
      payload[:measurements].each do |measurement|
        assert_not_nil measurement.dig(:trends, :change_24h)
        assert_not_nil measurement.dig(:trends, :yoy)
        assert_not_nil measurement.dig(:extremes, :high)
        assert_not_nil measurement.dig(:extremes, :low)
      end
    end

    continuous_priors = sql.count { |q| q.include?("continuous_observations") && q.include?("DISTINCT ON") }
    continuous_lookups = sql.count { |q| q.include?("FROM \"continuous_observations\"") }
    peak_scoped = sql.count { |q| q.include?("FROM \"peak_observations\"") && q.include?("peak_kind") }
    daily_ordered = sql.count { |q| q.include?("FROM \"daily_observations\"") && q.include?("ORDER BY") }
    daily_yoy = sql.count { |q| q.include?("FROM \"daily_observations\"") && q.include?("observed_on") && q.include?("LIMIT") }

    assert_equal 1, continuous_priors, "expected one batched continuous prior query, got:\n#{sql.join("\n")}"
    assert_equal 0, continuous_lookups, "expected no per-series continuous lookups, got:\n#{sql.join("\n")}"
    assert_equal 0, peak_scoped, "expected peaks from preload, got:\n#{sql.join("\n")}"
    assert_equal 0, daily_ordered, "expected daily extremes from preload, got:\n#{sql.join("\n")}"
    assert_equal 0, daily_yoy, "expected YoY from preload, got:\n#{sql.join("\n")}"
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

  test "network payload includes upstream and downstream catalog neighbors" do
    origin = create(:monitoring_location, site_number: "00000011", usgs_monitoring_location_id: "USGS-00000011")
    up = create(
      :monitoring_location,
      site_number: "00000012",
      usgs_monitoring_location_id: "USGS-00000012",
      name: "Upstream Creek near Town",
      slug: "upstream-creek-near-town",
      latitude: 47.52,
      longitude: -121.80,
      has_discharge: true,
      latest_discharge_value: 800.0,
      latest_discharge_unit: "ft3/s"
    )
    down = create(
      :monitoring_location,
      site_number: "00000013",
      usgs_monitoring_location_id: "USGS-00000013",
      name: "Downstream Creek near Town",
      slug: "downstream-creek-near-town",
      latitude: 47.48,
      longitude: -121.82,
      has_water_level: true,
      latest_water_level_value: 3.1,
      latest_water_level_unit: "ft"
    )
    origin.update!(upstream_station_ids: [ up.id ], downstream_station_ids: [ down.id ])

    payload = StationSnapshotCache.warm(origin.reload)
    network = payload[:network]

    assert_equal 1, network[:upstream].size
    assert_equal "00000012", network[:upstream].first[:site_number]
    assert_equal "discharge", network[:upstream].first[:measurements].first[:kind]
    assert_equal 1, network[:downstream].size
    assert_equal "00000013", network[:downstream].first[:site_number]
    assert_equal "water_level", network[:downstream].first[:measurements].first[:kind]
  end

  test "loads nearby and network neighbor cards in one query" do
    origin = create(:monitoring_location, site_number: "00000021", usgs_monitoring_location_id: "USGS-00000021")
    nearby = create(:monitoring_location, site_number: "00000022", usgs_monitoring_location_id: "USGS-00000022")
    up = create(:monitoring_location, site_number: "00000023", usgs_monitoring_location_id: "USGS-00000023")
    down = create(:monitoring_location, site_number: "00000024", usgs_monitoring_location_id: "USGS-00000024")
    origin.update!(
      nearby_station_ids: [ nearby.id ],
      upstream_station_ids: [ up.id ],
      downstream_station_ids: [ down.id ]
    )

    sql = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if payload[:name] == "SCHEMA"

      sql << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      payload = StationSnapshotCache.warm(origin.reload)
      assert_equal 1, payload[:nearby].size
      assert_equal 1, payload[:network][:upstream].size
      assert_equal 1, payload[:network][:downstream].size
    end

    neighbor_lookups = sql.count { |q| q.include?("FROM \"monitoring_locations\"") && q.include?("\"id\" IN") }
    assert_equal 1, neighbor_lookups
  end
end
