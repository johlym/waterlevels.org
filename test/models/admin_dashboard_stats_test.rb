require "test_helper"

class AdminDashboardStatsTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    AdminDashboardStats.clear_jobs!
    AdminDashboardStats.bust_backfill_cache!
  end

  teardown do
    AdminDashboardStats.clear_jobs!
    AdminDashboardStats.bust_backfill_cache!
    redis = Redis.new(RedisConfig.options)
    redis.scan_each(match: "history_backfill*") { |key| redis.del(key) }
  rescue StandardError
    nil
  end

  test "tip freshness histogram buckets stations by age" do
    travel_to Time.find_zone!("America/Los_Angeles").local(2026, 8, 3, 15, 0, 0) do
      create(:monitoring_location, state_code: "wa", latest_observed_at: 30.minutes.ago)
      create(:monitoring_location, state_code: "or", latest_observed_at: 2.hours.ago)
      create(:monitoring_location, state_code: "id", latest_observed_at: 12.hours.ago)
      create(:monitoring_location, state_code: "ca", latest_observed_at: 36.hours.ago)
      create(:monitoring_location, state_code: "nv", latest_observed_at: 4.days.ago)
      create(:monitoring_location, state_code: "az", latest_observed_at: 2.weeks.ago)
      create(:monitoring_location, state_code: "ut", latest_observed_at: nil)
      create(:monitoring_location, active: false, latest_observed_at: 30.minutes.ago)

      freshness = AdminDashboardStats.snapshot[:tip_freshness]

      assert_equal 1, freshness[:current]
      assert_equal 1, freshness[:h1_plus]
      assert_equal 1, freshness[:h6_plus]
      assert_equal 1, freshness[:h24_plus]
      assert_equal 1, freshness[:h72_plus]
      assert_equal 2, freshness[:stale]
    end
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
      AdminDashboardStats.record_job_finish!(
        :daily_archive_export,
        finished_at: 3.hours.ago,
        series: 12,
        points: 340
      )
      AdminDashboardStats.record_job_finish!(
        :iv_repair_batch,
        finished_at: 10.minutes.ago,
        enqueued: 7,
        candidates: 40,
        workers: 1,
        queue_depth_after: 7
      )
      AdminDashboardStats.record_job_finish!(
        :iv_repair,
        finished_at: 5.minutes.ago,
        site_number: "12101000",
        continuous_upserted: 48,
        still_needs: false,
        elapsed_s: 1.2
      )

      stats = AdminDashboardStats.snapshot

      assert_equal 2, stats[:station_count]
      assert_equal 1, stats[:stale_station_count]
      assert_equal 2, stats[:measurement_count]
      assert_equal 0, stats[:archive_daily_observation_count]
      assert_equal 1, stats[:updates_today]
      assert_equal 4, stats[:last_tip_refresh_stations_updated]
      assert_equal 9, stats[:last_tip_refresh_series_upserted]
      assert_nil stats[:last_tip_refresh_state]
      assert_equal fresh.site_number, stats[:last_station_updated][:site_number]
      assert_equal 1, stats[:tip_freshness][:current]
      assert_equal 0, stats[:tip_freshness][:h1_plus]
      assert_equal 0, stats[:tip_freshness][:h6_plus]
      assert_equal 0, stats[:tip_freshness][:h24_plus]
      assert_equal 0, stats[:tip_freshness][:h72_plus]
      assert_equal 1, stats[:tip_freshness][:stale]
      assert_equal 1, stats[:continuous_last_24h]
      assert_equal 1, stats[:continuous_last_7d]
      assert_equal "wa", stats[:last_catalog_sync_state]
      assert stats[:last_catalog_sync_at]
      assert stats[:last_flood_sync_at]
      assert stats[:last_prune_at]
      assert stats[:last_daily_archive_export_at]
      assert_equal 12, stats[:last_daily_archive_export_series]
      assert_equal 340, stats[:last_daily_archive_export_points]
      assert stats[:last_iv_repair_batch_at]
      assert_equal 7, stats[:last_iv_repair_batch_enqueued]
      assert_equal 40, stats[:last_iv_repair_batch_candidates]
      assert_equal 1, stats[:last_iv_repair_batch_workers]
      assert stats[:last_iv_repair_at]
      assert_equal "12101000", stats[:last_iv_repair_site_number]
      assert_equal 48, stats[:last_iv_repair_continuous_upserted]
      assert_equal false, stats[:last_iv_repair_still_needs]
      assert_equal 40, stats[:stations_needing_iv_repair]
      assert stats[:iv_repair_candidates_scanned_at]
      assert_equal 2, stats[:per_state].size
      wa = stats[:per_state].find { |row| row[:state_code] == "wa" }
      assert_equal 1, wa[:station_count]
      assert_equal "Washington", wa[:state_name]
      assert wa.key?(:missing_year_history)
      assert wa.key?(:history_ready)
      assert wa.key?(:has_year_history)
      assert wa.key?(:has_deep_history)
      assert wa.key?(:has_continuous_tip)
      assert wa.key?(:missing_daily_tip)
      assert_equal(
        wa[:station_count],
        wa[:needing_history] + wa[:needing_deep_history] + wa[:history_ready]
      )
      assert_equal(
        stats[:station_count],
        stats[:stations_needing_history] +
          stats[:stations_needing_deep_history] +
          stats[:stations_history_ready]
      )
      assert stats.key?(:stations_missing_year_history)
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_continuous"
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_daily"
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_peaks"
      assert_includes stats[:history_circuits].map { |c| c[:key] }, "history_iv_repair"
      assert_equal "tip", stats[:usgs_keys][:tip][:key]
      assert_equal false, stats[:tip_circuit_open]
      assert_equal false, stats[:database_read_only]
      assert stats[:sidekiq].key?(:enqueued) || stats[:sidekiq].key?(:error)
      refute stats.key?(:usgs_request_budgets)
    end
  end

  test "snapshot reflects open purpose-pinned history circuits" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    previous_env = {
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
    Usgs::RateLimitCircuit.open!(key_id: "history_daily", ttl: 1.minute)

    stats = AdminDashboardStats.snapshot
    daily = stats[:history_circuits].find { |c| c[:key] == "history_daily" }
    continuous = stats[:history_circuits].find { |c| c[:key] == "history_continuous" }
    assert_equal true, daily[:open]
    assert_equal false, continuous[:open]
    assert_equal false, stats[:history_keys_exhausted]
  ensure
    Rails.cache = previous_cache
    previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "measurement totals include fully cold archive shard points" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      location = create(:monitoring_location, state_code: "wa", latest_observed_at: 1.hour.ago)
      series = create(:time_series, monitoring_location: location, parameter_code: "00060")
      ContinuousObservation.create!(time_series: series, value: 1, observed_at: 1.hour.ago)
      DailyObservation.create!(time_series: series, value: 2, observed_on: Date.current)
      cold_day = Date.new(2024, 6, 1)
      DailyArchiveShard.create!(
        time_series: series,
        year: cold_day.year,
        object_key: "daily/v1/#{series.id}/#{cold_day.year}.json.gz",
        content_sha256: "deadbeef",
        point_count: 5,
        min_on: cold_day,
        max_on: cold_day,
        source_mix: "usgs",
        synced_at: Time.current
      )

      stats = AdminDashboardStats.snapshot
      assert_equal 5, stats[:archive_daily_observation_count]
      assert_equal 1 + 1 + 5, stats[:measurement_count]
    end
  end

  test "per_state treats archive-only deep history as ready" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      archive_ready = create(:monitoring_location, state_code: "id", latest_observed_at: 1.hour.ago)
      series = create(:time_series, monitoring_location: archive_ready, parameter_code: "00060")
      ContinuousObservation.create!(time_series: series, value: 1, observed_at: 1.hour.ago)
      ContinuousObservation.create!(
        time_series: series,
        value: 1,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago
      )
      DailyObservation.create!(time_series: series, value: 1, observed_on: Date.current)
      DailyObservation.create!(
        time_series: series,
        value: 1,
        observed_on: HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
      )
      deep_day = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
      DailyArchiveShard.create!(
        time_series: series,
        year: deep_day.year,
        object_key: "daily/v1/#{series.id}/#{deep_day.year}.json.gz",
        content_sha256: "cafe",
        point_count: 12,
        min_on: deep_day,
        max_on: deep_day,
        source_mix: "usgs",
        synced_at: Time.current
      )

      stats = AdminDashboardStats.snapshot
      id_row = stats[:per_state].find { |row| row[:state_code] == "id" }
      assert_equal 1, id_row[:station_count]
      assert_equal 0, id_row[:needing_history]
      assert_equal 0, id_row[:needing_deep_history]
      assert_equal 1, id_row[:history_ready]
      assert_equal 1, stats[:stations_history_ready]
      assert_equal 0, stats[:stations_needing_deep_history]
    end
  end

  test "per_state partitions phase-1 year-ready and deep-ready stations" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      cold = create(:monitoring_location, state_code: "ar", latest_observed_at: 1.hour.ago)
      year_ready = create(:monitoring_location, state_code: "ar", latest_observed_at: 1.hour.ago)
      deep_ready = create(:monitoring_location, state_code: "ar", latest_observed_at: 1.hour.ago)

      cold_series = create(:time_series, monitoring_location: cold, parameter_code: "00060")
      ContinuousObservation.create!(
        time_series: cold_series,
        value: 1,
        observed_at: 1.hour.ago
      )
      DailyObservation.create!(
        time_series: cold_series,
        value: 1,
        observed_on: Date.current
      )

      year_series = create(:time_series, monitoring_location: year_ready, parameter_code: "00060")
      ContinuousObservation.create!(
        time_series: year_series,
        value: 2,
        observed_at: 1.hour.ago
      )
      ContinuousObservation.create!(
        time_series: year_series,
        value: 2,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago
      )
      DailyObservation.create!(
        time_series: year_series,
        value: 2,
        observed_on: Date.current
      )
      DailyObservation.create!(
        time_series: year_series,
        value: 2,
        observed_on: HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
      )

      deep_series = create(:time_series, monitoring_location: deep_ready, parameter_code: "00060")
      ContinuousObservation.create!(
        time_series: deep_series,
        value: 3,
        observed_at: 1.hour.ago
      )
      ContinuousObservation.create!(
        time_series: deep_series,
        value: 3,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago
      )
      DailyObservation.create!(
        time_series: deep_series,
        value: 3,
        observed_on: Date.current
      )
      DailyObservation.create!(
        time_series: deep_series,
        value: 3,
        observed_on: HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
      )
      DailyObservation.create!(
        time_series: deep_series,
        value: 3,
        observed_on: HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
      )

      stats = AdminDashboardStats.snapshot
      ar = stats[:per_state].find { |row| row[:state_code] == "ar" }

      assert_equal 3, ar[:station_count]
      assert_equal 3, ar[:selected_count]
      assert_equal 3, ar[:has_continuous_tip]
      assert_equal 2, ar[:has_continuous_anchor]
      assert_equal 2, ar[:has_year_history]
      assert_equal 1, ar[:has_deep_history]
      assert_equal 1, ar[:needing_history]
      assert_equal 1, ar[:missing_year_history]
      assert_equal 1, ar[:needing_deep_history]
      assert_equal 1, ar[:history_ready]
    end
  end

  test "per_state counts archive-only daily tip as year-ready needing deep" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      location = create(:monitoring_location, state_code: "mt", latest_observed_at: 1.hour.ago)
      series = create(:time_series, monitoring_location: location, parameter_code: "00060")
      year_day = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date

      ContinuousObservation.create!(time_series: series, value: 1, observed_at: 1.hour.ago)
      ContinuousObservation.create!(
        time_series: series,
        value: 1,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago
      )
      # Fully drained Postgres daily tip — only R2 shard catalog remains.
      DailyArchiveShard.create!(
        time_series: series,
        year: year_day.year,
        object_key: "daily/v1/#{series.id}/#{year_day.year}.json.gz",
        content_sha256: "archive-tip",
        point_count: 40,
        min_on: year_day,
        max_on: Date.current,
        source_mix: "usgs",
        synced_at: Time.current
      )

      stats = AdminDashboardStats.snapshot
      mt = stats[:per_state].find { |row| row[:state_code] == "mt" }

      assert_equal 1, mt[:station_count]
      assert_equal 1, mt[:has_year_history]
      assert_equal 1, mt[:has_daily_tip]
      assert_equal 0, mt[:needing_history]
      assert_equal 0, mt[:missing_daily_tip]
      assert_equal 1, mt[:needing_deep_history]
      assert_equal 0, mt[:history_ready]
      assert_equal 1, stats[:stations_needing_deep_history]
    end
  end

  test "counts history backfill locks and cooldowns from Redis" do
    redis = Redis.new(RedisConfig.options)
    begin
      redis.ping
    rescue Redis::BaseError
      skip "Redis unavailable"
    end

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

  test "section snapshots compose into the full snapshot" do
    create(:monitoring_location, state_code: "wa", latest_observed_at: 30.minutes.ago)

    full = AdminDashboardStats.snapshot
    composed = AdminDashboardStats::SECTIONS.each_with_object({}) do |name, hash|
      hash.merge!(AdminDashboardStats.section(name))
    end

    assert_equal full.keys.sort, composed.keys.sort
    assert_equal full[:station_count], composed[:station_count]
    assert_equal full[:per_state], composed[:per_state]
    assert_equal full[:tip_freshness], composed[:tip_freshness]
  end

  test "warm_backfill! returns backfill aggregates" do
    create(:monitoring_location, state_code: "wa", latest_observed_at: 30.minutes.ago)
    AdminDashboardStats.bust_backfill_cache!

    warmed = AdminDashboardStats.warm_backfill!

    assert_equal 1, warmed[:station_count]
    assert warmed.key?(:per_state)
    assert_equal warmed[:station_count], AdminDashboardStats.snapshot[:station_count]
  end

  test "pipeline iv repair count uses last scanned candidates without live eligibility scan" do
    scanned_at = 12.minutes.ago
    AdminDashboardStats.record_job_finish!(
      :iv_repair_batch,
      finished_at: scanned_at,
      enqueued: 3,
      candidates: 17,
      workers: 1
    )

    with_iv_repair_scan_forbidden do
      stats = AdminDashboardStats.new.pipeline_section
      assert_equal 17, stats[:stations_needing_iv_repair]
      assert_in_delta scanned_at.to_i, stats[:iv_repair_candidates_scanned_at].to_i, 1
    end
  end

  test "skipped iv repair batch finish preserves last candidate count" do
    AdminDashboardStats.record_job_finish!(
      :iv_repair_batch,
      finished_at: 20.minutes.ago,
      enqueued: 5,
      candidates: 22,
      workers: 1
    )

    # Skips (queue busy, circuit, Sunday, batch_lock_held) must not wipe the
    # dedicated candidate count used by the pipeline panel.
    %w[iv_repair_queue_busy batch_lock_held].each do |reason|
      AdminDashboardStats.record_job_finish!(
        :iv_repair_batch,
        finished_at: Time.current,
        skipped_run: true,
        skip_reason: reason,
        elapsed_s: 0.1,
        workers: 1
      )
      assert_equal 22, AdminDashboardStats.last_iv_repair_candidates, reason
      assert_nil AdminDashboardStats.last_job(:iv_repair_batch)[:candidates], reason
    end

    with_iv_repair_scan_forbidden do
      stats = AdminDashboardStats.new.pipeline_section
      assert_equal 22, stats[:stations_needing_iv_repair]
    end
  end

  def with_iv_repair_scan_forbidden
    eigen = MonitoringLocation.singleton_class
    eigen.alias_method :__orig_iv_repair_candidate_ids, :iv_repair_candidate_ids
    eigen.define_method(:iv_repair_candidate_ids) do
      raise "live IV repair eligibility scan"
    end
    yield
  ensure
    eigen.alias_method :iv_repair_candidate_ids, :__orig_iv_repair_candidate_ids
    eigen.remove_method :__orig_iv_repair_candidate_ids
  end

  test "unknown section raises" do
    assert_raises(ArgumentError) { AdminDashboardStats.section(:nope) }
  end
end
