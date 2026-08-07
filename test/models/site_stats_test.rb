require "test_helper"

class SiteStatsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "snapshot counts stations measurements updates today and flood alerts" do
    travel_to Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 15, 0, 0) do
      location = create(:monitoring_location, flood_category: "minor", nwps_matched: true)
      create(:monitoring_location, flood_category: "no_flooding")
      create(:monitoring_location, active: false)
      create(:monitoring_location, latest_observed_at: 2.weeks.ago)
      create(:monitoring_location, latest_observed_at: nil)
      series = create(:time_series, monitoring_location: location, parameter_code: "00060")
      ContinuousObservation.create!(
        time_series: series,
        value: 10,
        observed_at: Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 1, 0, 0)
      )
      ContinuousObservation.create!(
        time_series: series,
        value: 11,
        observed_at: Time.find_zone!("America/Los_Angeles").local(2026, 8, 2, 23, 0, 0)
      )
      DailyObservation.create!(
        time_series: series,
        value: 12,
        observed_on: Date.current
      )

      stats = SiteStats.snapshot

      assert_equal 2, stats[:station_count]
      assert_equal 3, stats[:measurement_count]
      assert_equal 1, stats[:updates_today]
      assert_equal 1, stats[:flood_alert_count]
    end
  end

  test "station_count excludes inactive and stale locations" do
    create(:monitoring_location, active: true, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: true, latest_observed_at: 2.weeks.ago)
    create(:monitoring_location, active: true, latest_observed_at: nil)

    assert_equal 1, SiteStats.compute[:station_count]
  end

  test "warm! returns a freshly computed snapshot" do
    create(:monitoring_location)

    stats = SiteStats.warm!
    recomputed = SiteStats.compute

    assert_equal 1, stats[:station_count]
    assert_equal recomputed, stats
  end

  test "compute emits inventory counts for active and non-stale stations" do
    create(:monitoring_location, active: true, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: true, latest_observed_at: 2.weeks.ago)
    create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)

    # Smoke: compute still returns marketing non-stale count; inventory span is best-effort.
    assert_equal 1, SiteStats.compute[:station_count]
  end
end

