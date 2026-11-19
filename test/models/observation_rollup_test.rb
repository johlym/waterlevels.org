require "test_helper"

class ObservationRollupTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    AdminCounter.bust_request_cache!
  end

  test "insert and delete maintain hourly counts for the series shard" do
    series = create(:time_series, selected_for_display: true)
    other = create(:time_series, selected_for_display: false)
    observed_at = Time.utc(2026, 8, 3, 15, 20, 0)

    ContinuousObservation.create!(time_series: series, value: 1, observed_at: observed_at)
    ContinuousObservation.create!(time_series: series, value: 2, observed_at: observed_at + 10.minutes)
    ContinuousObservation.create!(time_series: other, value: 3, observed_at: observed_at)

    row = ObservationRollup.find_by!(dataset: 0, shard: series.id % 16, bucket: observed_at.beginning_of_hour)
    assert_equal 2, row.point_count
    assert_equal 2, row.selected_point_count

    unselected = ObservationRollup.find_by!(dataset: 0, shard: other.id % 16, bucket: observed_at.beginning_of_hour)
    assert_equal 1, unselected.point_count
    assert_equal 0, unselected.selected_point_count

    ContinuousObservation.where(time_series: series).delete_all

    assert_nil ObservationRollup.find_by(dataset: 0, shard: series.id % 16, bucket: observed_at.beginning_of_hour)
    assert_equal 1, unselected.reload.point_count
  end

  test "upsert of an existing point does not add another count" do
    series = create(:time_series)
    observed_at = Time.utc(2026, 8, 3, 15, 20, 0)
    now = Time.current
    row = {
      time_series_id: series.id,
      observed_at: observed_at,
      value: 1,
      created_at: now,
      updated_at: now
    }

    ContinuousObservation.upsert_all([ row ], unique_by: %i[time_series_id observed_at])
    ContinuousObservation.upsert_all([ row.merge(value: 2) ], unique_by: %i[time_series_id observed_at])

    assert_equal 1, ObservationRollup.summary[:continuous][:lifetime]
    assert_equal 1, ContinuousObservation.count
  end

  test "daily and peak rows count toward their own datasets" do
    series = create(:time_series)
    DailyObservation.create!(time_series: series, value: 1, observed_on: Date.new(2026, 8, 3))
    PeakObservation.create!(time_series: series, water_year: 2026, value: 9, peak_kind: "high")

    summary = ObservationRollup.summary
    assert_equal 1, summary[:daily][:lifetime]
    assert_equal 1, summary[:peak][:lifetime]
    assert_equal 0, summary[:continuous][:lifetime]
  end

  test "windows are hour aligned and today follows the Pacific day" do
    series = create(:time_series, selected_for_display: true)
    zone = Time.find_zone!("America/Los_Angeles")
    travel_to zone.local(2026, 8, 3, 15, 40, 0) do
      # 21:30 UTC is the hour before the 24h cutoff (22:00 UTC). 22:10 UTC is inside it.
      ContinuousObservation.create!(time_series: series, value: 1, observed_at: Time.utc(2026, 8, 2, 21, 30, 0))
      ContinuousObservation.create!(time_series: series, value: 2, observed_at: Time.utc(2026, 8, 2, 22, 10, 0))
      ContinuousObservation.create!(time_series: series, value: 3, observed_at: Time.utc(2026, 7, 31, 18, 0, 0))
      ContinuousObservation.create!(time_series: series, value: 4, observed_at: Time.utc(2026, 7, 24, 18, 0, 0))
      ContinuousObservation.create!(time_series: series, value: 5, observed_at: zone.local(2026, 8, 3, 1, 0, 0))
      ContinuousObservation.create!(time_series: series, value: 6, observed_at: zone.local(2026, 8, 2, 23, 0, 0))

      continuous = ObservationRollup.summary[:continuous]
      assert_equal 3, continuous[:last_24h]
      assert_equal 5, continuous[:last_7d]
      assert_equal 3, continuous[:last_24h_selected]
      assert_equal 1, continuous[:today]
      assert_equal 6, continuous[:lifetime]
    end
  end

  test "rebuild restores counts and applies the current selected flag" do
    series = create(:time_series, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, value: 1, observed_at: Time.utc(2026, 8, 3, 12, 0, 0))
    ObservationRollup.update_all(point_count: 99, selected_point_count: 0)
    series.update!(selected_for_display: false)

    ObservationRollup.rebuild!

    row = ObservationRollup.find_by!(dataset: 0, shard: series.id % 16)
    assert_equal 1, row.point_count
    assert_equal 0, row.selected_point_count
    assert_equal 1, ObservationRollup.summary[:continuous][:lifetime]
  end

  test "homepage snapshot reloads the published counter after a cache flush" do
    create(:monitoring_location, latest_observed_at: 1.hour.ago)
    AdminCounter.set!(
      AdminDashboardStats::INVENTORY_KEY,
      value: 1,
      source: "schedule",
      measurement_count: 40,
      updates_today: 7
    )
    SiteStats.bust!

    queries = []
    callback = ->(*, payload) { queries << payload[:sql].to_s }
    stats = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      stats = SiteStats.snapshot
    end

    assert_equal 40, stats[:measurement_count]
    assert_equal 7, stats[:updates_today]
    assert_not queries.any? { |sql| sql.include?("observation_rollups") }
    assert_not queries.any? { |sql| sql.match?(/FROM "continuous_observations"/) }
  end

  test "inventory refresh does not count continuous_observations" do
    series = create(:time_series)
    travel_to Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 15, 0, 0) do
      ContinuousObservation.create!(time_series: series, value: 1, observed_at: 1.hour.ago)
      AdminDashboardStats.bust_backfill_cache!

      queries = []
      callback = ->(*, payload) { queries << payload[:sql].to_s }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        AdminDashboardStats.refresh_inventory_counters!(source: "schedule")
      end

      assert_not queries.any? { |sql|
        sql.match?(/count\(\*\).*continuous_observations|FROM "continuous_observations"/i)
      }
      payload = AdminCounter.payload_for(AdminDashboardStats::INVENTORY_KEY)
      assert_equal 1, payload[:continuous_observation_count]
      assert_equal 1, payload[:continuous_last_24h]
      assert_equal 1, payload[:updates_today]
    end
  end
end
