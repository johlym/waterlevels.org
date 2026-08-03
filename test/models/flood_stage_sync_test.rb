require "test_helper"

class FloodStageSyncTest < ActiveSupport::TestCase
  setup do
    @location = create(
      :monitoring_location,
      site_number: "01646500",
      usgs_monitoring_location_id: "USGS-01646500",
      has_water_level: true
    )
    @unmatched = create(
      :monitoring_location,
      site_number: "99999999",
      usgs_monitoring_location_id: "USGS-99999999",
      state_code: "wa"
    )
  end

  test "applies NWPS thresholds and observed flood category" do
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { gauges: [] }.to_json)
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "BRKM2",
          usgsId: "01646500",
          flood: {
            categories: {
              action: { stage: 5 },
              minor: { stage: 10 },
              moderate: { stage: 12 },
              major: { stage: 14 }
            }
          },
          status: {
            observed: {
              floodCategory: "action",
              validTime: "2026-08-03T01:45:00Z"
            }
          }
        }.to_json
      )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999").to_return(status: 404, body: "{}")

    FloodStageSync.new(state: "wa").perform

    @location.reload
    assert @location.nwps_matched?
    assert_equal "BRKM2", @location.nwps_lid
    assert_equal "action", @location.flood_category
    assert_in_delta 5.0, @location.flood_stage_action, 0.001
    assert_in_delta 10.0, @location.flood_stage_minor, 0.001
    assert @location.flood_alert?

    @unmatched.reload
    assert_not @unmatched.nwps_matched?
    assert_nil @unmatched.flood_category
    assert_not_nil @unmatched.nwps_synced_at
  end

  test "list refresh updates category for known LIDs without detail GETs" do
    @location.update!(
      nwps_lid: "THET2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "no_flooding",
      flood_stage_minor: 25
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          gauges: [
            {
              lid: "THET2",
              state: { abbreviation: "TX" },
              status: {
                observed: { floodCategory: "major", validTime: "2026-08-03T04:15:00Z" },
                forecast: { floodCategory: "major", validTime: "2026-08-03T06:00:00Z" }
              }
            }
          ]
        }.to_json
      )

    FloodStageSync.new.perform

    @location.reload
    assert_equal "major", @location.flood_category
    assert_in_delta 25.0, @location.flood_stage_minor, 0.001
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500"
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999"
  end

  test "uses more severe forecast category when observed is not current" do
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { gauges: [] }.to_json)
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "BRKM2",
          flood: { categories: { action: { stage: 5 }, minor: { stage: 10 }, moderate: { stage: 12 }, major: { stage: 14 } } },
          status: {
            observed: { floodCategory: "obs_not_current", validTime: "0001-01-01T00:00:00Z" },
            forecast: { floodCategory: "moderate", validTime: "2026-08-03T12:00:00Z" }
          }
        }.to_json
      )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999").to_return(status: 404, body: "{}")

    FloodStageSync.new(state: "wa").perform

    @location.reload
    assert_equal "moderate", @location.flood_category
  end

  test "skips unmatched sites that were checked recently" do
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { gauges: [] }.to_json)
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "BRKM2",
          flood: { categories: { action: { stage: 5 }, minor: { stage: 10 }, moderate: { stage: 12 }, major: { stage: 14 } } },
          status: { observed: { floodCategory: "no_flooding", validTime: "2026-08-03T01:45:00Z" } }
        }.to_json
      )

    FloodStageSync.new(state: "wa").perform

    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999"
  end

  test "skips detail refresh for recently matched sites" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "action"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { gauges: [] }.to_json)

    FloodStageSync.new(state: "wa").perform

    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500"
  end
end
