require "test_helper"

class SiteStatsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "snapshot counts stations measurements recent updates and flood alerts" do
    location = create(:monitoring_location, flood_category: "minor", nwps_matched: true)
    create(:monitoring_location, flood_category: "no_flooding")
    series = create(:time_series, monitoring_location: location, parameter_code: "00060")
    ContinuousObservation.create!(
      time_series: series,
      value: 10,
      observed_at: 30.minutes.ago
    )
    ContinuousObservation.create!(
      time_series: series,
      value: 11,
      observed_at: 2.hours.ago
    )
    DailyObservation.create!(
      time_series: series,
      value: 12,
      observed_on: Date.current
    )

    stats = SiteStats.snapshot

    assert_equal 2, stats[:station_count]
    assert_equal 3, stats[:measurement_count]
    assert_equal 1, stats[:updates_per_hour]
    assert_equal 1, stats[:flood_alert_count]
  end
end
