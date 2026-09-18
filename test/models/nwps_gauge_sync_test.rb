require "test_helper"

class NwpsGaugeSyncTest < ActiveSupport::TestCase
  setup do
    @entry = Nwps::GaugeCatalog.find_by_site_number("nwpsacrw1")
    @client = Object.new
    def @client.gauge(_lid)
      {
        "lid" => "ACRW1",
        "usgsId" => "",
        "name" => "Alpowa Creek at Mouth",
        "status" => {
          "observed" => {
            "primary" => 1.3,
            "primaryUnit" => "ft",
            "floodCategory" => "no_flooding",
            "validTime" => "2026-09-18T03:15:00Z"
          },
          "forecast" => { "floodCategory" => "fcst_not_current" }
        },
        "flood" => {
          "categories" => {
            "action" => { "stage" => -9999 },
            "minor" => { "stage" => -9999 },
            "moderate" => { "stage" => -9999 },
            "major" => { "stage" => -9999 }
          }
        }
      }
    end
  end

  test "sync upserts nwps location series tip and denorm water level" do
    count = NwpsGaugeSync.new(client: @client).perform(entries: [ @entry ])
    assert_equal 1, count

    location = MonitoringLocation.find_by!(site_number: "nwpsacrw1")
    assert_equal DataProviders::NWPS, location.data_provider
    assert_equal "NWPS-ACRW1", location.provider_location_id
    assert_equal "ACRW1", location.nwps_lid
    assert location.nwps_matched?
    assert_equal "wa", location.state_code
    assert location.has_water_level?
    assert_in_delta 1.3, location.latest_water_level_value.to_f, 0.001
    assert_equal Nwps::ParameterCodes::STAGE, location.latest_water_level_parameter_code
    assert_equal "no_flooding", location.flood_category

    series = location.time_series.sole
    assert_equal "NWPS-ACRW1-stage", series.provider_series_id
    assert_equal "water_level", series.measurement_kind
    assert series.selected_for_display?
  end

  test "skips lids that publish a usgsId" do
    linked = Object.new
    def linked.gauge(_lid)
      { "lid" => "BHDA3", "usgsId" => "09421500", "status" => { "observed" => { "primary" => 48.9 } } }
    end

    entry = Nwps::GaugeCatalog::Entry.new(
      lid: "BHDA3",
      site_number: "nwpsbhda3",
      name: "Should Skip",
      state_code: "az",
      state_name: "Arizona",
      latitude: 36.0,
      longitude: -114.7,
      time_zone: "MST",
      parameter_code: Nwps::ParameterCodes::STAGE,
      unit_of_measure: "ft",
      parameter_description: "test"
    )

    assert_equal 0, NwpsGaugeSync.new(client: linked).perform(entries: [ entry ])
    assert_nil MonitoringLocation.find_by(site_number: "nwpsbhda3")
  end

  test "usgs history callouts stay gated off for nwps locations" do
    NwpsGaugeSync.new(client: @client).perform(entries: [ @entry ])
    location = MonitoringLocation.find_by!(site_number: "nwpsacrw1")

    assert_not location.usgs?
    assert_not location.known_missing_usgs_iv?
  end
end
