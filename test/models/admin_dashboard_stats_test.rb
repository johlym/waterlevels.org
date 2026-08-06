require "test_helper"

class AdminDashboardStatsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    AdminDashboardStats.clear_jobs!
  end

  teardown do
    AdminDashboardStats.clear_jobs!
    redis = Redis.new(RedisConfig.options)
    redis.scan_each(match: "history_backfill*") { |key| redis.del(key) }
  rescue StandardError
    nil
  end

  test "snapshot reports station measurement and tip refresh stats" do
    travel_to Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 15, 0, 0) do
      fresh = create(:monitoring_location, state_code: "wa", latest_observed_at: 30.minutes.ago)
      stale = create(:monitoring_location, state_code: "or", latest_observed_at: 2.weeks.ago)
      inactive = create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)
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
      AdminDashboardStats.record_job_finish!(:catalog_sync, finished_at: 2.hours.ago, state: "wa")
      AdminDashboardStats.record_job_finish!(:flood_sync, finished_at: 90.minutes.ago)
      AdminDashboardStats.record_job_finish!(:prune, finished_at: 1.day.ago)

      stats = AdminDashboardStats.snapshot

      assert_equal 2, stats[:station_count]
      assert_equal 1, stats[:stale_station_count]
      assert_equal 2, stats[:measurement_count]
      assert_equal 1, stats[:updates_today]
      assert_equal 4, stats[:last_tip_refresh_stations_updated]
      assert_equal 9, stats[:last_tip_refresh_series_upserted]
      assert_nil stats[:last_tip_refresh_state]
      assert_equal fresh.site_number, stats[:last_station_updated][:site_number]
      assert_equal 1, stats[:tip_freshness][:under_1h]
      assert_equal 1, stats[:tip_freshness][:stale]
      assert_equal 1, stats[:continuous_last_24h]
      assert_equal 1, stats[:continuous_last_7d]
      assert_equal "wa", stats[:last_catalog_sync_state]
      assert stats[:last_catalog_sync_at]
      assert stats[:last_flood_sync_at]
      assert stats[:last_prune_at]
      assert_equal 2, stats[:per_state].size
      wa = stats[:per_state].find { |row| row[:state_code] == "wa" }
      assert_equal 1, wa[:station_count]
      assert_equal "Washington", wa[:state_name]
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_1"
      assert_equal false, stats[:tip_circuit_open]
      assert_equal false, stats[:database_read_only]
      assert stats[:sidekiq].key?(:enqueued) || stats[:sidekiq].key?(:error)
    end
  end

  test "counts history backfill locks and cooldowns from Redis" do
    redis = Redis.new(RedisConfig.options)
    redis.set("#{HistoryBackfillLock::KEY_PREFIX}1", "1")
    redis.set("#{HistoryBackfillLock::KEY_PREFIX}2", "1")
    redis.set("#{HistoryBackfillLock::COOLDOWN_PREFIX}9", "1")

    stats = AdminDashboardStats.snapshot
    assert_equal 2, stats[:history_backfill_locks]
    assert_equal 1, stats[:history_backfill_cooldowns]
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
