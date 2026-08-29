require "test_helper"

class GaugesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @location = create(:monitoring_location)
  end

  test "renders the canonical gauge page" do
    series = create(:time_series, monitoring_location: @location, parameter_code: "00065")
    LatestObservation.create!(
      time_series: series,
      value: 12.34,
      unit_of_measure: "ft",
      observed_at: Time.utc(2026, 8, 2, 4, 30, 0),
      synced_at: Time.current,
      approval_status: "Provisional"
    )
    @location.update!(
      latest_water_level_value: 12.34,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_observed_at: Time.utc(2026, 8, 2, 4, 30, 0),
      latest_approval_status: "Provisional",
      time_zone: "PST"
    )

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Example River Near Town"
    assert_includes response.body, "Gage height"
    assert_includes response.body, "role=\"tablist\""
    assert_includes response.body, ">King<"
    assert_not_includes response.body, "King County"
    assert_includes response.body, "August 1, 2026 at 09:30:00 PM PDT"
    assert_includes response.body, 'data-hydrograph-time-zone-value="America/Los_Angeles"'
    assert_includes response.body, 'data-hydrograph-time-zone-label-value="PST"'
    assert_includes response.body, "No flood stage data"
    assert_includes response.body, 'class="term-tip"'
    assert_includes response.body, ">Provisional<span"
    assert_includes response.body, "not finished review"
    assert_includes response.headers["Cache-Tag"], "gauge:#{@location.site_number}"
    assert_includes response.headers["Cache-Control"], "max-age=60"
    assert_not_includes response.headers["Cache-Control"], "stale-while-revalidate"
    assert_includes response.headers["Cloudflare-CDN-Cache-Control"], "stale-while-revalidate=86400"
    assert_includes response.body, 'name="turbo-cache-control" content="no-cache"'
  end

  test "measurement labels include glossary tooltips for datum terms" do
    series = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00062",
      parameter_description: "Height above datum"
    )
    LatestObservation.create!(
      time_series: series,
      value: 8.5,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    @location.update!(
      latest_water_level_value: 8.5,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00062",
      latest_observed_at: 1.hour.ago
    )

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Height above "
    assert_includes response.body, ">datum<span"
    assert_includes response.body, 'class="term-tip-bubble"'
    assert_includes response.body, "reference surface"
  end

  test "breadcrumb strips County suffix from county names" do
    @location.update!(county_name: "King County")

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, ">King<"
    assert_not_includes response.body, "King County"
  end

  test "breadcrumb county links to state directory county anchor" do
    @location.update!(county_name: "King County")

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, 'href="/gauges/wa#king"'
    assert_includes response.body, ">King</a>"
  end

  test "gauge page shows NWS flood category and stage thresholds" do
    @location.update!(
      nwps_matched: true,
      nwps_lid: "BRKM2",
      flood_category: "minor",
      flood_stage_action: 5,
      flood_stage_minor: 10,
      flood_stage_moderate: 12,
      flood_stage_major: 14,
      latest_observed_at: 1.hour.ago
    )

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Minor Flooding"
    assert_includes response.body, "badge flood-minor"
    assert_includes response.body, "NWS flood stages"
    assert_includes response.body, "Action 5 ft"
    assert_includes response.body, "data-hydrograph-flood-stages-value"
    assert_includes response.body, "&quot;minor&quot;:10.0"
    assert_not_includes response.body, "No flood stage data"
  end

  test "shows history callout when full-year daily history is missing" do
    series = create(:time_series, monitoring_location: @location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Historical trends"
    assert_includes response.body, 'class="history-callout"'
    assert_includes response.body, "Full-year history is still loading"
  end

  test "hides history callout when full-year daily history is present" do
    series = create(:time_series, monitoring_location: @location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Historical trends"
    assert_not_includes response.body, 'class="history-callout"'
    assert_not_includes response.body, "Full-year history is still loading"
    assert_includes response.body, 'data-hydrograph-range-param="1y"'
    assert_not_includes response.body, 'data-hydrograph-range-param="3y"'
  end

  test "shows unavailable callout when USGS daily is absent for a parameter" do
    stage = create(
      :time_series,
      monitoring_location: @location,
      selected_for_display: true,
      usgs_daily_absent: true,
      parameter_code: "00065",
      measurement_kind: "water_level"
    )
    ContinuousObservation.create!(time_series: stage, observed_at: 1.hour.ago, value: 5.5)
    flow = create(
      :time_series,
      monitoring_location: @location,
      selected_for_display: true,
      parameter_code: "00060",
      measurement_kind: "discharge"
    )
    DailyObservation.create!(time_series: flow, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: flow, observed_on: Date.current, value: 11.0)

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, 'class="history-callout"'
    assert_not_includes response.body, "Full-year history is still loading"
    assert_includes response.body, "USGS does not publish daily history for Gage height"
  end

  test "shows known-missing USGS IV callout with the next check time" do
    series = create(:time_series, monitoring_location: @location, selected_for_display: true)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 5.days.ago
      )
      seed_continuous_coverage!(
        series,
        from: 3.days.ago,
        to: 1.hour.ago
      )
      TimeSeries.record_iv_scar_check!([ series.id ])

      get "/gauges/#{@location.state_code}/#{@location.to_param}"
      assert_response :success
      assert_includes response.body, 'class="history-callout"'
      assert_includes response.body, "USGS is missing data that would fill a gap"
      assert_includes response.body, "We'll check USGS again"
      assert_includes response.body, "August 10, 2026"
    end
  end

  test "shows 3 year range tab when deep daily history is present" do
    series = create(:time_series, monitoring_location: @location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: 35.months.ago.to_date, value: 9.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, 'data-hydrograph-range-param="3y"'
    assert_includes response.body, "3 Years"
  end

  test "nearby stations show all available measurements" do
    neighbor = create(
      :monitoring_location,
      site_number: "00000999",
      usgs_monitoring_location_id: "USGS-00000999",
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
    @location.update!(nearby_station_ids: [ neighbor.id ])

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "Nearby stations"
    assert_includes response.body, "Neighbor Creek Near Town"
    assert_includes response.body, "Flow:"
    assert_includes response.body, "1,250"
    assert_includes response.body, "Level:"
    assert_includes response.body, "4.25"
    assert_includes response.body, 'data-temp-prefix="Temp: "'
    assert_includes response.body, 'data-temp-c="12.8"'
  end

  test "on-stream timeline renders upstream and downstream neighbors" do
    up = create(
      :monitoring_location,
      site_number: "00000888",
      usgs_monitoring_location_id: "USGS-00000888",
      name: "Upstream Fork near Town",
      slug: "upstream-fork-near-town",
      latitude: 47.52,
      longitude: -121.80,
      has_discharge: true,
      latest_discharge_value: 640.0,
      latest_discharge_unit: "ft3/s",
      latest_observed_at: 20.minutes.ago
    )
    down = create(
      :monitoring_location,
      site_number: "00000777",
      usgs_monitoring_location_id: "USGS-00000777",
      name: "Downstream Fork near Town",
      slug: "downstream-fork-near-town",
      latitude: 47.48,
      longitude: -121.82,
      has_water_level: true,
      latest_water_level_value: 5.5,
      latest_water_level_unit: "ft",
      latest_observed_at: 20.minutes.ago
    )
    @location.update!(upstream_station_ids: [ up.id ], downstream_station_ids: [ down.id ])

    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_includes response.body, "On this stream"
    assert_includes response.body, "This station"
    assert_includes response.body, "Upstream Fork Near Town"
    assert_includes response.body, "Downstream Fork Near Town"
    assert_includes response.body, "aria-current=\"page\""
    assert_includes response.body, "network-timeline"
  end

  test "hides the on-stream timeline when both sides are empty" do
    get "/gauges/#{@location.state_code}/#{@location.to_param}"
    assert_response :success
    assert_not_includes response.body, "On this stream"
    assert_not_includes response.body, "network-timeline"
  end

  test "map stations include station time zone fields" do
    @location.update!(time_zone: "CST", state_code: "tx", state_name: "Texas", latitude: 30.27, longitude: -97.74)

    api_get "/api/map/stations", params: { bbox: "-98,30,-97,31" }
    assert_response :success
    station = JSON.parse(response.body)["stations"].find { |row| row["id"] == @location.site_number }
    assert_equal "CST", station["time_zone"]
    assert_equal "America/Chicago", station["time_zone_identifier"]
  end

  test "map stations include flood category fields" do
    @location.update!(
      flood_category: "moderate",
      nwps_matched: true,
      flood_stage_action: 5,
      flood_stage_minor: 10,
      flood_stage_moderate: 12,
      flood_stage_major: 14,
      latitude: 47.5,
      longitude: -121.8
    )

    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    station = JSON.parse(response.body)["stations"].find { |row| row["id"] == @location.site_number }
    assert_equal "moderate", station["flood_category"]
    assert_equal "Moderate Flood", station["flood_category_label"]
    assert station["flood_alert"]
    assert_in_delta 12.0, station["flood_stage_moderate"], 0.001
  end

  test "renders state listing grouped by county with titlecased locations" do
    create(:monitoring_location, site_number: "100", usgs_monitoring_location_id: "USGS-100", county_name: "Yakima", name: "Z RIVER NEAR TOWN, WA", state_code: "wa")
    create(:monitoring_location, site_number: "101", usgs_monitoring_location_id: "USGS-101", county_name: "Adams", name: "A CREEK NEAR TOWN, WA", state_code: "wa")

    get "/gauges/wa"
    assert_response :success
    assert_includes response.body, "Adams"
    assert_includes response.body, "Yakima"
    assert_includes response.body, "A Creek Near Town, WA"
    assert_includes response.body, "Z River Near Town, WA"
    assert_operator response.body.index("Adams"), :<, response.body.index("Yakima")
    assert_operator response.body.index("A Creek Near Town, WA"), :<, response.body.index("Z River Near Town, WA")
  end

  test "state listing shows critical alerts and flood card status" do
    create(
      :monitoring_location,
      site_number: "200",
      usgs_monitoring_location_id: "USGS-200",
      county_name: "King",
      name: "FLOOD CREEK NEAR TOWN, WA",
      state_code: "wa",
      flood_category: "action",
      nwps_matched: true,
      latest_water_level_value: 6.2,
      latest_water_level_unit: "ft",
      latest_observed_at: 30.minutes.ago
    )

    get "/gauges/wa"
    assert_response :success
    assert_includes response.body, "Critical Alerts"
    assert_includes response.body, "Action"
    assert_includes response.body, "status flood-action"
    assert_includes response.body, "elevated"
    assert_includes response.body, "Stations with alerts"
    assert_includes response.body, 'data-state-directory-target="alertsOnly"'
    assert_includes response.body, 'data-alert="true"'
  end

  test "state listing hides alerts filter when no stations have alerts" do
    create(
      :monitoring_location,
      site_number: "201",
      usgs_monitoring_location_id: "USGS-201",
      county_name: "King",
      name: "QUIET CREEK NEAR TOWN, WA",
      state_code: "wa",
      flood_category: "no_flooding"
    )

    get "/gauges/wa"
    assert_response :success
    assert_not_includes response.body, "Stations with alerts"
    assert_not_includes response.body, 'data-state-directory-target="alertsOnly"'
    assert_includes response.body, 'data-alert="false"'
  end

  test "returns map stations for a bbox" do
    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_kind_of Array, json["stations"]
  end

  test "map station popup payload reflects denormalized tip columns" do
    observed_at = Time.utc(2026, 8, 5, 14, 15, 0)
    @location.update!(
      latitude: 47.5,
      longitude: -121.8,
      latest_water_level_value: 7.5,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_discharge_value: 1200.0,
      latest_discharge_unit: "ft3/s",
      latest_observed_at: observed_at
    )

    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    station = JSON.parse(response.body)["stations"].find { |row| row["id"] == @location.site_number }
    assert station
    assert_in_delta 7.5, station["water_level"], 0.001
    assert_in_delta 1200.0, station["discharge"], 0.001
    assert_equal observed_at.iso8601, station["observed_at"]
  end

  test "map station popup prefers fresher LatestObservation over lagging columns" do
    older = Time.utc(2026, 8, 2, 7, 30, 0)
    newer = Time.utc(2026, 8, 5, 18, 30, 0)
    @location.update!(
      latitude: 47.5,
      longitude: -121.8,
      latest_water_level_value: 23.95,
      latest_water_level_unit: "ft",
      latest_water_level_parameter_code: "00065",
      latest_observed_at: older
    )
    series = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    LatestObservation.create!(
      time_series: series,
      value: 23.80,
      unit_of_measure: "ft",
      observed_at: newer,
      synced_at: Time.current
    )

    api_get "/api/map/stations", params: { bbox: "-125,45,-120,49" }
    assert_response :success
    station = JSON.parse(response.body)["stations"].find { |row| row["id"] == @location.site_number }
    assert station
    assert_in_delta 23.80, station["water_level"], 0.001
    assert_equal newer.iso8601, station["observed_at"]
  end

  test "searches all monitoring locations without a bbox" do
    in_view = create(
      :monitoring_location,
      site_number: "12101000",
      usgs_monitoring_location_id: "USGS-12101000",
      name: "SNOHOMISH RIVER NEAR MONROE, WA",
      latitude: 47.85,
      longitude: -122.0,
      state_code: "wa"
    )
    out_of_view = create(
      :monitoring_location,
      site_number: "01646500",
      usgs_monitoring_location_id: "USGS-01646500",
      name: "POTOMAC RIVER NEAR WASH, DC",
      latitude: 38.95,
      longitude: -77.13,
      state_code: "md"
    )

    api_get "/api/map/stations/search", params: { q: "potomac" }
    assert_response :success
    stations = JSON.parse(response.body)["stations"]
    ids = stations.map { |row| row["id"] }

    assert_includes ids, out_of_view.site_number
    assert_not_includes ids, in_view.site_number
    assert_equal "/gauges/md/#{out_of_view.to_param}", stations.first["path"]
    assert_not stations.first.key?("lat")
  end

  test "station search requires at least two characters" do
    create(:monitoring_location, name: "POTOMAC RIVER NEAR WASH, DC", state_code: "md")

    api_get "/api/map/stations/search", params: { q: "p" }
    assert_response :success
    assert_equal [], JSON.parse(response.body)["stations"]
  end

  test "station search includes matching state first when there is no exact location match" do
    station = create(
      :monitoring_location,
      site_number: "08158000",
      usgs_monitoring_location_id: "USGS-08158000",
      name: "Colorado Rv at Austin, TX",
      state_code: "tx",
      state_name: "Texas"
    )

    api_get "/api/map/stations/search", params: { q: "Texas" }
    assert_response :success
    results = JSON.parse(response.body)["stations"]

    assert_equal "state", results.first["type"]
    assert_equal "Texas", results.first["name"]
    assert_equal "/gauges/tx", results.first["path"]
    assert_includes results.map { |row| row["id"] }, station.site_number
  end

  test "station search omits state result when an exact location match exists" do
    create(
      :monitoring_location,
      site_number: "99990001",
      usgs_monitoring_location_id: "USGS-99990001",
      name: "Texas",
      state_code: "tx",
      state_name: "Texas"
    )

    api_get "/api/map/stations/search", params: { q: "Texas" }
    assert_response :success
    results = JSON.parse(response.body)["stations"]

    assert results.none? { |row| row["type"] == "state" }
    assert_equal "station", results.first["type"]
    assert_equal "Texas", results.first["name"]
  end

  test "nearest station returns the closest location path" do
    create(:monitoring_location, site_number: "20000001", latitude: 47.0, longitude: -122.0)
    near = create(:monitoring_location, site_number: "20000002", latitude: 47.05, longitude: -122.05)

    api_get "/api/map/stations/nearest", params: { lat: 47.051, lon: -122.051 }
    assert_response :success
    station = JSON.parse(response.body)["station"]
    assert_equal near.site_number, station["id"]
    assert_equal "/gauges/#{near.path_state}/#{near.to_param}", station["path"]
  end

  test "station search returns a ZIP result that links to a zoomed map view" do
    stub_request(:get, "https://api.zippopotam.us/us/98101")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "post code" => "98101",
          "places" => [
            {
              "place name" => "Seattle",
              "longitude" => "-122.3305",
              "latitude" => "47.6114",
              "state" => "Washington",
              "state abbreviation" => "WA"
            }
          ]
        }.to_json
      )

    api_get "/api/map/stations/search", params: { q: "98101" }
    assert_response :success
    results = JSON.parse(response.body)["stations"]

    assert_equal "zip", results.first["type"]
    assert_equal "98101", results.first["id"]
    assert_equal "98101 — Seattle, WA", results.first["name"]
    assert_equal "/map?lat=47.6114&lon=-122.3305&zoom=12", results.first["path"]
    assert_not results.first.key?("lat")
  end

  test "station search accepts ZIP+4 and still returns the five-digit map result" do
    stub_request(:get, "https://api.zippopotam.us/us/78701")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "post code" => "78701",
          "places" => [
            {
              "place name" => "Austin",
              "longitude" => "-97.7428",
              "latitude" => "30.2711",
              "state" => "Texas",
              "state abbreviation" => "TX"
            }
          ]
        }.to_json
      )

    api_get "/api/map/stations/search", params: { q: "78701-0143" }
    assert_response :success
    results = JSON.parse(response.body)["stations"]

    assert_equal "zip", results.first["type"]
    assert_equal "/map?lat=30.2711&lon=-97.7428&zoom=12", results.first["path"]
  end

  test "station search omits ZIP results when the provider has no match" do
    stub_request(:get, "https://api.zippopotam.us/us/00000")
      .to_return(status: 404, body: "{}")

    api_get "/api/map/stations/search", params: { q: "00000" }
    assert_response :success
    results = JSON.parse(response.body)["stations"]

    assert results.none? { |row| row["type"] == "zip" }
  end
end
