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
    stub_nwps_gauges(gauges: [])
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
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "no_flooding",
      flood_stage_minor: 10,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "BRKM2",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "minor", validTime: "2026-08-03T04:15:00Z" },
            forecast: { floodCategory: "action", validTime: "2026-08-03T06:00:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    @location.reload
    assert_equal "minor", @location.flood_category
    assert_in_delta 10.0, @location.flood_stage_minor, 0.001
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500"
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999"
  end

  test "matches unlinked action-plus gauges from the list via LID detail and usgsId" do
    flooding = create(
      :monitoring_location,
      site_number: "08210000",
      usgs_monitoring_location_id: "USGS-08210000",
      state_code: "tx",
      state_name: "Texas",
      has_water_level: true
    )
    @location.update!(nwps_matched: true, nwps_lid: "KEEP", nwps_synced_at: 1.hour.ago)
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.hour.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "THET2",
          state: { abbreviation: "TX" },
          status: {
            observed: { floodCategory: "major", validTime: "2026-08-03T04:15:00Z" },
            forecast: { floodCategory: "major", validTime: "2026-08-03T06:00:00Z" }
          }
        },
        {
          lid: "TILT2",
          state: { abbreviation: "TX" },
          status: {
            observed: { floodCategory: "moderate", validTime: "2026-08-03T04:00:00Z" },
            forecast: { floodCategory: "moderate", validTime: "2026-08-03T06:00:00Z" }
          }
        },
        {
          lid: "QUIET",
          state: { abbreviation: "TX" },
          status: {
            observed: { floodCategory: "no_flooding", validTime: "2026-08-03T04:00:00Z" }
          }
        }
      ]
    )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/THET2")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "THET2",
          usgsId: "8210000", # unpadded on purpose — sync should still match 08210000
          flood: {
            categories: {
              action: { stage: 20 },
              minor: { stage: 25 },
              moderate: { stage: 27 },
              major: { stage: 35 }
            }
          },
          status: {
            observed: { floodCategory: "major", validTime: "2026-08-03T04:15:00Z" },
            forecast: { floodCategory: "major", validTime: "2026-08-03T06:00:00Z" }
          }
        }.to_json
      )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/TILT2")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "TILT2",
          usgsId: "08206600",
          flood: {
            categories: {
              action: { stage: 10 },
              minor: { stage: 14 },
              moderate: { stage: 17 },
              major: { stage: 20 }
            }
          },
          status: {
            observed: { floodCategory: "moderate", validTime: "2026-08-03T04:00:00Z" }
          }
        }.to_json
      )

    FloodStageSync.new(state: "tx").perform

    flooding.reload
    assert flooding.nwps_matched?
    assert_equal "THET2", flooding.nwps_lid
    assert_equal "major", flooding.flood_category
    assert_in_delta 35.0, flooding.flood_stage_major, 0.001
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/QUIET"
  end

  test "uses more severe forecast category when observed is not current" do
    stub_nwps_gauges(gauges: [])
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
    stub_nwps_gauges(gauges: [])
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

    stub_nwps_gauges(gauges: [])

    FloodStageSync.new(state: "wa").perform

    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500"
  end

  test "detail 404 on a matched site keeps the LID and live flood category" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 8.days.ago,
      flood_category: "major",
      flood_category_observed_at: 2.hours.ago,
      flood_stage_action: 5,
      flood_stage_minor: 10,
      flood_stage_moderate: 12,
      flood_stage_major: 14,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(gauges: [])
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/BRKM2")
      .to_return(status: 404, body: "{}")
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
      .to_return(status: 404, body: "{}")

    FloodStageSync.new(state: "wa").perform

    @location.reload
    assert @location.nwps_matched?
    assert_equal "BRKM2", @location.nwps_lid
    assert_equal "major", @location.flood_category
    assert @location.flood_alert?
    assert_in_delta 10.0, @location.flood_stage_minor, 0.001
    assert @location.nwps_synced_at > 1.minute.ago
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500"
  end

  test "list refresh skips write and snapshot warm when category is unchanged" do
    observed_at = Time.zone.parse("2026-08-03T04:15:00Z")
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "minor",
      flood_category_observed_at: observed_at,
      flood_stage_minor: 10,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)
    prior_updated_at = @location.reload.updated_at

    stub_nwps_gauges(
      gauges: [
        {
          lid: "BRKM2",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "minor", validTime: "2026-08-03T04:15:00Z" }
          }
        }
      ]
    )

    assert_no_changes -> { @location.reload.updated_at.to_i } do
      FloodStageSync.new(state: "wa").perform
    end
    assert_equal prior_updated_at.to_i, @location.reload.updated_at.to_i
  end

  test "list fetch uses the state's bbox instead of a national gauges list" do
    stub_nwps_gauges(gauges: [])
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
      .to_return(status: 404, body: "{}")
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999")
      .to_return(status: 404, body: "{}")

    FloodStageSync.new(state: "wa").perform

    bbox = Usgs::StateCodes.bbox_for("wa")
    assert_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges",
      query: {
        "bbox.xmin" => bbox.fetch(:xmin).to_s,
        "bbox.ymin" => bbox.fetch(:ymin).to_s,
        "bbox.xmax" => bbox.fetch(:xmax).to_s,
        "bbox.ymax" => bbox.fetch(:ymax).to_s,
        "srid" => "EPSG_4326"
      }
  end

  test "requires a state" do
    assert_raises(ArgumentError) { FloodStageSync.new.perform }
  end

  test "expires a stale alert when the LID is absent from a successful list" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "major",
      flood_category_observed_at: 36.hours.ago,
      flood_stage_minor: 10,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "OTHER",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "no_flooding", validTime: "2026-08-03T04:15:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    @location.reload
    assert_equal "no_flooding", @location.flood_category
    assert_not @location.flood_alert?
    assert_in_delta 10.0, @location.flood_stage_minor, 0.001
    assert @location.nwps_matched?
  end

  test "keeps a recent alert when the LID is absent from the list" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "major",
      flood_category_observed_at: 2.hours.ago,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "OTHER",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "no_flooding", validTime: "2026-08-03T04:15:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    assert_equal "major", @location.reload.flood_category
  end

  test "does not expire stale alerts when the list fetch fails" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "major",
      flood_category_observed_at: 36.hours.ago,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_request(:get, %r{\Ahttps://api\.water\.noaa\.gov/nwps/v1/gauges\?})
      .to_return(status: 400, body: "bad request")

    FloodStageSync.new(state: "wa").perform

    assert_equal "major", @location.reload.flood_category
  end

  test "does not expire stale alerts when the list is empty" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "major",
      flood_category_observed_at: 36.hours.ago,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(gauges: [])

    FloodStageSync.new(state: "wa").perform

    assert_equal "major", @location.reload.flood_category
  end

  test "expires a stale alert when the list only reports non-current sentinels" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "moderate",
      flood_category_observed_at: 36.hours.ago,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "BRKM2",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "obs_not_current", validTime: "0001-01-01T00:00:00Z" },
            forecast: { floodCategory: "fcst_not_current", validTime: "0001-01-01T00:00:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    assert_equal "no_flooding", @location.reload.flood_category
  end

  test "keeps a recent alert when the list only reports non-current sentinels" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "moderate",
      flood_category_observed_at: 2.hours.ago,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "BRKM2",
          state: { abbreviation: "WA" },
          status: {
            observed: { floodCategory: "obs_not_current", validTime: "0001-01-01T00:00:00Z" },
            forecast: { floodCategory: "fcst_not_current", validTime: "0001-01-01T00:00:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    assert_equal "moderate", @location.reload.flood_category
  end

  test "list refresh updates a known LID even when NWPS classifies it in a neighbor state" do
    @location.update!(
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 2.hours.ago,
      flood_category: "major",
      flood_category_observed_at: 2.hours.ago,
      flood_stage_minor: 10,
      state_code: "wa"
    )
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.day.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "BRKM2",
          state: { abbreviation: "OR" },
          status: {
            observed: { floodCategory: "no_flooding", validTime: "2026-08-03T04:15:00Z" }
          }
        }
      ]
    )

    FloodStageSync.new(state: "wa").perform

    assert_equal "no_flooding", @location.reload.flood_category
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/BRKM2"
  end

  test "caps detail GETs per run so national sync stays finite" do
    previous = ENV["NWPS_DETAIL_REQUEST_BUDGET"]
    ENV["NWPS_DETAIL_REQUEST_BUDGET"] = "1"

    third = create(
      :monitoring_location,
      site_number: "01646501",
      usgs_monitoring_location_id: "USGS-01646501",
      state_code: "wa",
      nwps_synced_at: nil
    )
    @location.update!(nwps_synced_at: nil)
    @unmatched.update!(nwps_synced_at: nil)

    detail_gets = 0
    stub_nwps_gauges(gauges: [])
    stub_request(:get, %r{\Ahttps://api\.water\.noaa\.gov/nwps/v1/gauges/})
      .to_return do |_request|
        detail_gets += 1
        { status: 404, body: "{}", headers: { "Content-Type" => "application/json" } }
      end

    FloodStageSync.new(state: "wa").perform

    synced = [ @location, @unmatched, third ].count { |loc| loc.reload.nwps_synced_at.present? }
    assert_equal 1, synced
    assert_equal 1, detail_gets
  ensure
    previous.nil? ? ENV.delete("NWPS_DETAIL_REQUEST_BUDGET") : ENV["NWPS_DETAIL_REQUEST_BUDGET"] = previous
  end

  test "alert matching consumes shared detail budget before discovery" do
    previous = ENV["NWPS_DETAIL_REQUEST_BUDGET"]
    ENV["NWPS_DETAIL_REQUEST_BUDGET"] = "1"

    flooding = create(
      :monitoring_location,
      site_number: "08210000",
      usgs_monitoring_location_id: "USGS-08210000",
      state_code: "tx",
      state_name: "Texas",
      has_water_level: true,
      nwps_synced_at: nil
    )
    never_synced = create(
      :monitoring_location,
      site_number: "08210001",
      usgs_monitoring_location_id: "USGS-08210001",
      state_code: "tx",
      state_name: "Texas",
      nwps_synced_at: nil
    )
    @location.update!(nwps_matched: true, nwps_lid: "KEEP", nwps_synced_at: 1.hour.ago)
    @unmatched.update!(nwps_matched: false, nwps_synced_at: 1.hour.ago)

    stub_nwps_gauges(
      gauges: [
        {
          lid: "THET2",
          state: { abbreviation: "TX" },
          status: {
            observed: { floodCategory: "major", validTime: "2026-08-03T04:15:00Z" }
          }
        },
        {
          lid: "TILT2",
          state: { abbreviation: "TX" },
          status: {
            observed: { floodCategory: "moderate", validTime: "2026-08-03T04:00:00Z" }
          }
        }
      ]
    )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/THET2")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          lid: "THET2",
          usgsId: "08210000",
          flood: {
            categories: {
              action: { stage: 20 },
              minor: { stage: 25 },
              moderate: { stage: 27 },
              major: { stage: 35 }
            }
          },
          status: {
            observed: { floodCategory: "major", validTime: "2026-08-03T04:15:00Z" }
          }
        }.to_json
      )
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/TILT2")
      .to_return(status: 404, body: "{}")
    stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/08210001")
      .to_return(status: 404, body: "{}")

    FloodStageSync.new(state: "tx").perform

    flooding.reload
    assert flooding.nwps_matched?
    assert_equal "THET2", flooding.nwps_lid
    assert_nil never_synced.reload.nwps_synced_at
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/TILT2"
    assert_not_requested :get, "https://api.water.noaa.gov/nwps/v1/gauges/08210001"
  ensure
    previous.nil? ? ENV.delete("NWPS_DETAIL_REQUEST_BUDGET") : ENV["NWPS_DETAIL_REQUEST_BUDGET"] = previous
  end

  private

  def stub_nwps_gauges(gauges:)
    stub_request(:get, %r{\Ahttps://api\.water\.noaa\.gov/nwps/v1/gauges\?})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { gauges: gauges }.to_json
      )
  end
end
