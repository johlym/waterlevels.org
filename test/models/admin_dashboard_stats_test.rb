require "test_helper"

class AdminDashboardStatsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "snapshot reports station measurement and tip refresh stats" do
    travel_to Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 15, 0, 0) do
      fresh = create(:monitoring_location, latest_observed_at: 1.hour.ago)
      stale = create(:monitoring_location, latest_observed_at: 2.weeks.ago)
      inactive = create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)
      # Touch after creates so ordering is deterministic (create sets updated_at = now).
      stale.update_columns(updated_at: 2.weeks.ago)
      inactive.update_columns(updated_at: 3.days.ago)
      fresh.update_columns(updated_at: 1.hour.ago)

      series = create(:time_series, monitoring_location: fresh, parameter_code: "00060")
      ContinuousObservation.create!(
        time_series: series,
        value: 10,
        observed_at: Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 1, 0, 0)
      )
      DailyObservation.create!(time_series: series, value: 11, observed_on: Date.current)

      AdminDashboardStats.record_tip_refresh!(
        stations_updated: 4,
        series_upserted: 9,
        finished_at: Time.current,
        state: nil
      )

      stats = AdminDashboardStats.snapshot

      assert_equal 2, stats[:station_count]
      assert_equal 1, stats[:stale_station_count]
      assert_equal 2, stats[:measurement_count]
      assert_equal 1, stats[:updates_today]
      assert_equal 4, stats[:last_tip_refresh_stations_updated]
      assert_equal 9, stats[:last_tip_refresh_series_upserted]
      assert_nil stats[:last_tip_refresh_state]
      assert_equal fresh.site_number, stats[:last_station_updated][:site_number]
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_1"
      assert_equal false, stats[:tip_circuit_open]
      assert_equal false, stats[:database_read_only]
      assert stats[:sidekiq].key?(:enqueued) || stats[:sidekiq].key?(:error)
    end
  end

  test "record_tip_refresh! overwrites the cached tip summary" do
    AdminDashboardStats.record_tip_refresh!(stations_updated: 1, series_upserted: 1)
    AdminDashboardStats.record_tip_refresh!(stations_updated: 3, series_upserted: 5, state: "wa")

    tip = AdminDashboardStats.last_tip_refresh
    assert_equal 3, tip[:stations_updated]
    assert_equal 5, tip[:series_upserted]
    assert_equal "wa", tip[:state]
  end
end
