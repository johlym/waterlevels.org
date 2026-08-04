require "test_helper"

class MonitoringLocationTest < ActiveSupport::TestCase
  test "time_zone_identifier maps USGS abbreviation to IANA" do
    location = build(:monitoring_location, time_zone: "CST", state_code: "tx")
    assert_equal "America/Chicago", location.time_zone_identifier

    arizona = build(:monitoring_location, time_zone: "MST", state_code: "az")
    assert_equal "America/Phoenix", arizona.time_zone_identifier
  end

  test "flood helpers classify NWS categories" do
    location = build(:monitoring_location, flood_category: "major", flood_stage_minor: 10)
    assert location.flood_alert?
    assert_equal "Major Flooding", location.flood_category_label
    assert location.has_flood_stages?

    normal = build(:monitoring_location, flood_category: "no_flooding")
    assert_not normal.flood_alert?
    assert_equal "Normal", normal.flood_category_label
  end

  test "needing_history_backfill includes locations missing recent continuous or year daily" do
    needs_continuous = create(:monitoring_location, site_number: "20000001")
    create(:time_series, monitoring_location: needs_continuous, selected_for_display: true)

    needs_daily = create(:monitoring_location, site_number: "20000002")
    daily_series = create(:time_series, monitoring_location: needs_daily, selected_for_display: true)
    ContinuousObservation.create!(time_series: daily_series, observed_at: 1.day.ago, value: 12.3)

    needs_daily_tip = create(:monitoring_location, site_number: "20000004")
    tip_series = create(:time_series, monitoring_location: needs_daily_tip, selected_for_display: true)
    ContinuousObservation.create!(time_series: tip_series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: tip_series, observed_on: 11.months.ago.to_date, value: 10.0)

    complete = create(:monitoring_location, site_number: "20000003")
    series = create(:time_series, monitoring_location: complete, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    ids = MonitoringLocation.needing_history_backfill.pluck(:id)
    assert_includes ids, needs_continuous.id
    assert_includes ids, needs_daily.id
    assert_includes ids, needs_daily_tip.id
    refute_includes ids, complete.id
  end

  test "needs_history_backfill? is false without selected series" do
    location = create(:monitoring_location)
    create(:time_series, monitoring_location: location, selected_for_display: false)
    refute location.needs_history_backfill?
  end

  test "missing_year_history? is true without a daily point near the year anchor" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    assert location.missing_year_history?
  end

  test "missing_year_history? is false when year daily history is present" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    refute location.missing_year_history?
  end

  test "missing_year_history? is false without selected series" do
    location = create(:monitoring_location)
    create(:time_series, monitoring_location: location, selected_for_display: false)
    refute location.missing_year_history?
  end

  test "missing_deep_history? is false until year history exists" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    refute location.missing_deep_history?
    refute location.has_deep_history?
  end

  test "missing_deep_history? is true when year-ready but deep daily is absent" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    assert location.missing_deep_history?
    refute location.has_deep_history?
  end

  test "has_deep_history? is true when deep daily anchor is present" do
    location = create(:monitoring_location)
    series = create(:time_series, monitoring_location: location, selected_for_display: true)
    DailyObservation.create!(time_series: series, observed_on: 35.months.ago.to_date, value: 9.0)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

    refute location.missing_deep_history?
    assert location.has_deep_history?
  end

  test "needing_deep_history_backfill includes year-ready stations missing deep daily" do
    year_ready = create(:monitoring_location, site_number: "20000010")
    year_series = create(:time_series, monitoring_location: year_ready, selected_for_display: true)
    ContinuousObservation.create!(time_series: year_series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: year_series, observed_on: 11.months.ago.to_date, value: 10.0)
    DailyObservation.create!(time_series: year_series, observed_on: Date.current, value: 11.0)

    cold = create(:monitoring_location, site_number: "20000011")
    create(:time_series, monitoring_location: cold, selected_for_display: true)

    deep_ready = create(:monitoring_location, site_number: "20000012")
    deep_series = create(:time_series, monitoring_location: deep_ready, selected_for_display: true)
    ContinuousObservation.create!(time_series: deep_series, observed_at: 1.day.ago, value: 12.3)
    DailyObservation.create!(time_series: deep_series, observed_on: 35.months.ago.to_date, value: 9.0)
    DailyObservation.create!(time_series: deep_series, observed_on: Date.current, value: 11.0)

    ids = MonitoringLocation.needing_deep_history_backfill.pluck(:id)
    assert_includes ids, year_ready.id
    refute_includes ids, cold.id
    refute_includes ids, deep_ready.id
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

  test "search matches NWPS LID" do
    location = create(
      :monitoring_location,
      site_number: "08210000",
      usgs_monitoring_location_id: "USGS-08210000",
      name: "Nueces Rv nr Three Rivers, TX",
      state_code: "tx",
      state_name: "Texas",
      nwps_lid: "THET2",
      nwps_matched: true,
      flood_category: "major"
    )

    assert_equal [ location ], MonitoringLocation.search("THET2").to_a
    assert_equal [ location ], MonitoringLocation.search("thet2").to_a
  end

  test "persists expanded titlecase display_name and search_name from USGS shorthand" do
    location = create(
      :monitoring_location,
      name: "Lk Travis nr Austin, TX"
    )

    assert_equal "Lake Travis Near Austin, TX", location.display_name
    assert_equal "lake travis near austin, tx", location.search_name
  end

  test "search matches expanded names when query uses full words" do
    location = create(
      :monitoring_location,
      site_number: "08154700",
      usgs_monitoring_location_id: "USGS-08154700",
      name: "Lk Travis nr Austin, TX",
      state_code: "tx",
      state_name: "Texas"
    )

    assert_equal [ location ], MonitoringLocation.search("Lake Travis").to_a
    assert_equal [ location ], MonitoringLocation.search("lk travis").to_a
  end

  test "exact_search_match requires an exact name, site number, or NWPS LID" do
    location = create(
      :monitoring_location,
      site_number: "08154700",
      usgs_monitoring_location_id: "USGS-08154700",
      name: "Lk Travis nr Austin, TX",
      state_code: "tx",
      state_name: "Texas",
      nwps_lid: "ATIT2"
    )

    assert_includes MonitoringLocation.exact_search_match("08154700"), location
    assert_includes MonitoringLocation.exact_search_match("Lake Travis Near Austin, TX"), location
    assert_includes MonitoringLocation.exact_search_match("ATIT2"), location
    assert_not MonitoringLocation.exact_search_match("Texas").exists?
    assert_not MonitoringLocation.exact_search_match("Lake Travis").exists?
  end
end
