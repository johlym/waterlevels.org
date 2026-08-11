require "test_helper"

class IvRepairBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    AdminDashboardStats.clear_jobs!
    @previous_env = {
      "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"],
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
  end

  teardown do
    IvRepairBatchLock.release!
    Rails.cache = @previous_cache
    AdminDashboardStats.clear_jobs!
    @previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "enqueues iv repair jobs for anchored hollow-middle stations" do
    gappy = create(:monitoring_location, site_number: "30000201")
    series = create(:time_series, monitoring_location: gappy, selected_for_display: true)
    cold = create(:monitoring_location, site_number: "30000202")
    create(:time_series, monitoring_location: cold, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 12.hours.ago
      )
      ContinuousObservation.create!(time_series: series, observed_at: 30.minutes.ago, value: 12.5)
      DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 10.0)
      DailyObservation.create!(time_series: series, observed_on: Date.current, value: 11.0)

      assert_enqueued_with(job: IvRepairJob, args: [ gappy.id ]) do
        assert_equal 1, IvRepairBatchJob.perform_now(10)
      end
      assert_no_enqueued_jobs only: HistoryBackfillJob
      assert_equal 1, AdminDashboardStats.last_iv_repair_candidates
      assert AdminDashboardStats.last_iv_repair_candidates_scanned_at
    end
  end

  test "skips enqueueing when iv_repair circuit is open" do
    gappy = create(:monitoring_location, site_number: "30000203")
    series = create(:time_series, monitoring_location: gappy, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 6.hours.ago
      )
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair", ttl: 1.minute)
      assert_no_enqueued_jobs only: IvRepairJob do
        assert_equal 0, IvRepairBatchJob.perform_now(10)
      end
    end
  end

  test "skips enqueueing on Sunday" do
    gappy = create(:monitoring_location, site_number: "30000204")
    series = create(:time_series, monitoring_location: gappy, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 6.hours.ago
      )
      assert_no_enqueued_jobs only: IvRepairJob do
        assert_equal 0, IvRepairBatchJob.perform_now(10)
      end
    end
  end

  test "skips when another batch already holds the lock" do
    gappy = create(:monitoring_location, site_number: "30000205")
    series = create(:time_series, monitoring_location: gappy, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 6.hours.ago
      )
      assert IvRepairBatchLock.claim!
      assert_no_enqueued_jobs only: IvRepairJob do
        assert_equal 0, IvRepairBatchJob.perform_now(10)
      end
    end
  end
end
