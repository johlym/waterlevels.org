require "test_helper"

class UsaceProjectSyncTest < ActiveSupport::TestCase
  setup do
    @entry = Usace::ProjectCatalog.find_by_site_number("usacenabraystown")
    @client = Object.new
    def @client.each_timeseries_value(name:, office:, begin_at:, end_at:, unit: "ft", page_size: nil)
      yield Time.utc(2026, 9, 18, 5, 0, 0), 786.33, 3
    end
  end

  test "sync upserts location series tip and denorm water level" do
    count = UsaceProjectSync.new(client: @client).perform(entries: [ @entry ])
    assert_equal 1, count

    location = MonitoringLocation.find_by!(site_number: "usacenabraystown")
    assert_equal DataProviders::USACE, location.data_provider
    assert_equal "USACE-NAB-Raystown", location.provider_location_id
    assert_equal "pa", location.state_code
    assert location.has_water_level?
    assert_in_delta 786.33, location.latest_water_level_value.to_f, 0.001
    assert_equal Usace::ParameterCodes::ELEVATION, location.latest_water_level_parameter_code
    assert location.daily_only?

    series = location.time_series.sole
    assert_includes series.provider_series_id, "Raystown.Elev.Ave.~1Day.1Day.Best-NAB"
    assert_equal "water_level", series.measurement_kind
    assert series.selected_for_display?

    tip = series.latest_observation
    assert_in_delta 786.33, tip.value.to_f, 0.001
  end

  test "usgs history callouts stay gated off for usace locations" do
    UsaceProjectSync.new(client: @client).perform(entries: [ @entry ])
    location = MonitoringLocation.find_by!(site_number: "usacenabraystown")

    assert_not location.usgs?
    assert_not location.known_missing_usgs_iv?
  end
end
