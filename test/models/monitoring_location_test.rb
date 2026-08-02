require "test_helper"

class MonitoringLocationTest < ActiveSupport::TestCase
  test "time_zone_identifier maps USGS abbreviation to IANA" do
    location = build(:monitoring_location, time_zone: "CST", state_code: "tx")
    assert_equal "America/Chicago", location.time_zone_identifier

    arizona = build(:monitoring_location, time_zone: "MST", state_code: "az")
    assert_equal "America/Phoenix", arizona.time_zone_identifier
  end

  test "needing_history_backfill includes locations missing recent continuous or year daily" do
    needs_continuous = create(:monitoring_location, site_number: "20000001")
    create(:time_series, monitoring_location: needs_continuous, selected_for_display: true)

    needs_daily = create(:monitoring_location, site_number: "20000002")
    daily_series = create(:time_series, monitoring_location: needs_daily, selected_for_display: true)
    ContinuousObservation.create!(time_series: daily_series, observed_at: 1.day.ago, value: 12.3)

    complete = create(:monitoring_location, site_number: "20000003")
    series = create(:time_series, monitoring_location: complete, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)

    ids = MonitoringLocation.needing_history_backfill.pluck(:id)
    assert_includes ids, needs_continuous.id
    assert_includes ids, needs_daily.id
    refute_includes ids, complete.id
  end

  test "needs_history_backfill? is false without selected series" do
    location = create(:monitoring_location)
    create(:time_series, monitoring_location: location, selected_for_display: false)
    refute location.needs_history_backfill?
  end

  test "search matches name, site number, and state across the collection" do
    river = create(
      :monitoring_location,
      site_number: "01646500",
      usgs_monitoring_location_id: "USGS-01646500",
      name: "POTOMAC RIVER NEAR WASH, DC",
      state_code: "md",
      state_name: "Maryland"
    )
    other = create(
      :monitoring_location,
      site_number: "12101000",
      usgs_monitoring_location_id: "USGS-12101000",
      name: "SNOHOMISH RIVER NEAR MONROE, WA",
      state_code: "wa",
      state_name: "Washington"
    )

    assert_equal [ river ], MonitoringLocation.search("potomac").to_a
    assert_equal [ river ], MonitoringLocation.search("016465").to_a
    assert_includes MonitoringLocation.search("maryland"), river
    assert_not_includes MonitoringLocation.search("potomac"), other
  end
end
