require "test_helper"

class IvRepairScarBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    AdminDashboardStats.clear_jobs!
    @previous_env = {
      "USGS_API_HISTORY_IVREPAIR2_KEY" => ENV["USGS_API_HISTORY_IVREPAIR2_KEY"],
      "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"],
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_IVREPAIR2_KEY"] = "hist-iv-repair2"
    ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
  end

  teardown do
    IvRepairScarBatchLock.release!
    Rails.cache = @previous_cache
    AdminDashboardStats.clear_jobs!
    @previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "runs on the isolated iv_repair_scar queue" do
    assert_equal "iv_repair_scar", IvRepairScarBatchJob.new.queue_name
  end

  test "enqueues scar jobs for anchored stations with older interior holes" do
    location = create(:monitoring_location, site_number: "30000301")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 5.days.ago
      )
      seed_continuous_coverage!(
        series,
        from: 3.days.ago,
        to: 1.hour.ago
      )

      assert location.reload.needs_iv_scar_repair?
      refute location.needs_iv_repair?

      assert_enqueued_with(job: IvRepairScarJob, args: [ location.id ]) do
        assert_equal 1, IvRepairScarBatchJob.perform_now(10)
      end
      assert_no_enqueued_jobs only: IvRepairJob
    end
  end

  test "skips when iv_repair2 key is unset" do
    ENV.delete("USGS_API_HISTORY_IVREPAIR2_KEY")
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      assert_no_enqueued_jobs only: IvRepairScarJob do
        assert_equal 0, IvRepairScarBatchJob.perform_now(10)
      end
    end
  end

  test "skips when iv_repair2 circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair2", ttl: 1.minute)
      assert_no_enqueued_jobs only: IvRepairScarJob do
        assert_equal 0, IvRepairScarBatchJob.perform_now(10)
      end
    end
  end
end
