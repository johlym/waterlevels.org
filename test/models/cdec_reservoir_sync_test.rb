require "test_helper"

class CdecReservoirSyncTest < ActiveSupport::TestCase
  setup do
    @entry = Cdec::ReservoirCatalog.find_by_site_number("cdecoro")
    @client = Object.new
    def @client.each_reading(station_id:, sensor_num:, start_on:, end_on:, dur_code: "D")
      [
        { "date" => "2026-9-16 00:00", "value" => 771.07 },
        { "date" => "2026-9-17 00:00", "value" => 770.3 },
        { "date" => "2026-9-18 00:00", "value" => -9999 }
      ].each { |row| yield row }
    end
  end

  test "sync upserts location series tip and skips missing sentinel" do
    count = CdecReservoirSync.new(client: @client).perform(entries: [ @entry ])
    assert_equal 1, count

    location = MonitoringLocation.find_by!(site_number: "cdecoro")
    assert_not_includes MonitoringLocation.column_names, "agency_name"
    assert_equal "CDEC", location.agency_code
    assert_equal "California Data Exchange Center", location.agency_label
    assert_equal DataProviders::CDEC, location.data_provider
    assert_equal "CDEC-ORO", location.provider_location_id
    assert_equal "ca", location.state_code
    assert location.has_water_level?
    assert_in_delta 770.3, location.latest_water_level_value.to_f, 0.001
    assert_equal Cdec::ParameterCodes::ELEVATION, location.latest_water_level_parameter_code
    assert location.daily_only?

    series = location.time_series.sole
    assert_equal "CDEC-ORO-6", series.provider_series_id
    assert_equal "water_level", series.measurement_kind
    assert series.selected_for_display?
  end

  test "usgs history callouts stay gated off for cdec locations" do
    CdecReservoirSync.new(client: @client).perform(entries: [ @entry ])
    location = MonitoringLocation.find_by!(site_number: "cdecoro")

    assert_not location.usgs?
    assert_not location.known_missing_usgs_iv?
  end
end
