require "test_helper"

class MonitoringLocationTest < ActiveSupport::TestCase
  test "time_zone_identifier maps USGS abbreviation to IANA" do
    location = build(:monitoring_location, time_zone: "CST", state_code: "tx")
    assert_equal "America/Chicago", location.time_zone_identifier

    arizona = build(:monitoring_location, time_zone: "MST", state_code: "az")
    assert_equal "America/Phoenix", arizona.time_zone_identifier
  end

  test "needing_history_backfill includes locations with selected series but no recent continuous" do
    needs = create(:monitoring_location, site_number: "20000001")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    complete = create(:monitoring_location, site_number: "20000002")
    series = create(:time_series, monitoring_location: complete, selected_for_display: true)
    ContinuousObservation.create!(
      time_series: series,
      observed_at: 1.day.ago,
      value: 12.3
    )

    ids = MonitoringLocation.needing_history_backfill.pluck(:id)
    assert_includes ids, needs.id
    refute_includes ids, complete.id
  end

  test "needs_history_backfill? is false without selected series" do
    location = create(:monitoring_location)
    create(:time_series, monitoring_location: location, selected_for_display: false)
    refute location.needs_history_backfill?
  end
end
