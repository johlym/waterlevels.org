require "test_helper"

class UsbrReservoirSyncTest < ActiveSupport::TestCase
  setup do
    @entry = Usbr::ReservoirCatalog.active_entries.first
    @client = Object.new
    def @client.each_result(_item_id, items_per_page: 1)
      yield(
        "dateTime" => "2026-09-16T07:00:00Z",
        "result" => 1038.5,
        "status" => "Provisional"
      )
    end
  end

  test "sync upserts location series tip and denorm water level" do
    count = UsbrReservoirSync.new(client: @client).perform(entries: [ @entry ])
    assert_equal 1, count

    location = MonitoringLocation.find_by!(site_number: "usbr3514")
    assert_equal DataProviders::USBR, location.data_provider
    assert_equal "USBR-3514", location.provider_location_id
    assert_equal "nv", location.state_code
    assert location.has_water_level?
    assert_in_delta 1038.5, location.latest_water_level_value.to_f, 0.001
    assert_equal Usbr::ParameterCodes::ELEVATION, location.latest_water_level_parameter_code
    assert location.daily_only?

    series = location.time_series.sole
    assert_equal "USBR-item-6123", series.provider_series_id
    assert_equal "water_level", series.measurement_kind
    assert series.selected_for_display?

    tip = series.latest_observation
    assert_in_delta 1038.5, tip.value.to_f, 0.001
  end

  test "usgs history callouts stay gated off for usbr locations" do
    UsbrReservoirSync.new(client: @client).perform(entries: [ @entry ])
    location = MonitoringLocation.find_by!(site_number: "usbr3514")

    assert_not location.usgs?
    get_via_redirect = false
    # Predicate helpers must not imply USGS IV/daily-absent messaging paths.
    assert_not location.known_missing_usgs_iv?
  end
end
