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

  test "measurement_count includes fully cold archive shard points" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      location = create(:monitoring_location, latest_observed_at: 1.hour.ago)
      series = create(:time_series, monitoring_location: location, parameter_code: "00060")
      DailyObservation.create!(time_series: series, value: 1, observed_on: Date.current)
      cold_day = Date.new(2024, 6, 1)
      DailyArchiveShard.create!(
        time_series: series,
        year: cold_day.year,
        object_key: "daily/v1/#{series.id}/#{cold_day.year}.json.gz",
        content_sha256: "stats",
        point_count: 4,
        min_on: cold_day,
        max_on: cold_day,
        source_mix: "usgs",
        synced_at: Time.current
      )

      assert_equal 5, SiteStats.compute[:measurement_count]
    end
  end

  test "station_count excludes inactive and stale locations" do
    create(:monitoring_location, active: true, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: true, latest_observed_at: 2.weeks.ago)
    create(:monitoring_location, active: true, latest_observed_at: nil)

    assert_equal 1, SiteStats.compute[:station_count]
  end

  test "measurement_count does not double-count a day already in a gap-free shard" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      location = create(:monitoring_location, latest_observed_at: 1.hour.ago)
      series = create(:time_series, monitoring_location: location, parameter_code: "00060")
      day = Date.new(2024, 6, 1)
      DailyObservation.create!(time_series: series, value: 1, observed_on: day)
      DailyObservation.create!(time_series: series, value: 2, observed_on: Date.current)
      DailyArchiveShard.create!(
        time_series: series,
        year: day.year,
        object_key: "daily/v1/#{series.id}/#{day.year}.json.gz",
        content_sha256: "overlap",
        point_count: 1,
        min_on: day,
        max_on: day,
        source_mix: "usgs",
        synced_at: Time.current
      )

      assert_equal 1, DailyArchive.duplicated_postgres_daily_count
      # The archived day is one measurement. The current Postgres-only day is another.
      assert_equal 2, SiteStats.compute[:measurement_count]
    end
  end

  test "measurement_count keeps postgres days inside a gapped shard" do
    location = create(:monitoring_location, latest_observed_at: 1.hour.ago)
    series = create(:time_series, monitoring_location: location, parameter_code: "00060")
    DailyObservation.create!(time_series: series, value: 1, observed_on: Date.current)
    DailyArchiveShard.create!(
      time_series: series,
      year: Date.current.year,
      object_key: "daily/v1/#{series.id}/gapped.json.gz",
      content_sha256: "gapped",
      point_count: 1,
      min_on: Date.current - 30,
      max_on: Date.current,
      source_mix: "usgs",
      synced_at: Time.current
    )

    assert_equal 0, DailyArchive.duplicated_postgres_daily_count
    assert_equal 2, SiteStats.compute[:measurement_count]
  end

  test "estimate resolver prefers a live tuple count and exact count once that drops under the threshold" do
    counted = 0
    large = SiteStats.resolve_row_count(reltuples: 5_000_000, n_live_tup: 2_000_000) do
      counted += 1
      1
    end
    assert_equal 2_000_000, large
    assert_equal 0, counted

    shrunk = SiteStats.resolve_row_count(reltuples: 5_000_000, n_live_tup: 400) { 380 }
    assert_equal 380, shrunk

    unknown = SiteStats.resolve_row_count(reltuples: -1, n_live_tup: 0) { 4 }
    assert_equal 4, unknown

    collector_quiet = SiteStats.resolve_row_count(reltuples: 8_000, n_live_tup: 0) { flunk "should not COUNT" }
    assert_equal 8_000, collector_quiet
  end

  test "refresh_measurements false reuses totals and still counts new flood alerts" do
    with_memory_cache do
      create(:monitoring_location, flood_category: "minor", latest_observed_at: 1.hour.ago)
      first = SiteStats.warm!
      assert_equal 1, first[:flood_alert_count]

      create(:monitoring_location, flood_category: "major", latest_observed_at: 1.hour.ago)
      sql = capture_sql do
        ActiveRecord::Base.connection.uncached do
          second = SiteStats.warm!(refresh_measurements: false)
          assert_equal 2, second[:flood_alert_count]
          assert_equal first[:measurement_count], second[:measurement_count]
          assert_equal first[:updates_today], second[:updates_today]
        end
      end

      assert_not measurement_scan?(sql), "observation tables were recounted"
    end
  end

  test "refresh_measurements false scans observation tables once when the snapshot is cold" do
    with_memory_cache do
      ActiveRecord::Base.connection.uncached do
        first_sql = capture_sql { SiteStats.warm!(refresh_measurements: false) }
        second_sql = capture_sql { SiteStats.warm!(refresh_measurements: false) }
        assert measurement_scan?(first_sql)
        assert_not measurement_scan?(second_sql)
      end
    end
  end

  test "warm! returns a freshly computed snapshot" do
    create(:monitoring_location)

    stats = SiteStats.warm!
    recomputed = SiteStats.compute

    assert_equal 1, stats[:station_count]
    assert_equal recomputed, stats
  end

  def with_memory_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    SiteStats.bust!
    yield
  ensure
    SiteStats.bust!
    Rails.cache = previous
  end

  def capture_sql
    queries = []
    callback = ->(*, payload) { queries << payload[:sql].to_s }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def measurement_scan?(queries)
    queries.any? { |sql| sql.include?('FROM "continuous_observations"') || sql.include?("daily_archive_shards") }
  end

  test "compute emits inventory counts for active and non-stale stations" do
    create(:monitoring_location, active: true, latest_observed_at: 1.hour.ago)
    create(:monitoring_location, active: true, latest_observed_at: 2.weeks.ago)
    create(:monitoring_location, active: false, latest_observed_at: 1.hour.ago)

    # Smoke: compute still returns marketing non-stale count; inventory span is best-effort.
    assert_equal 1, SiteStats.compute[:station_count]
  end
end
