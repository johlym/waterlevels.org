require "test_helper"

class IvRepairScarJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
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
    Rails.cache = @previous_cache
    @previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "enqueue claims shared lock and requires iv_repair2 key" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert IvRepairScarJob.enqueue(99)
      assert_enqueued_with(job: IvRepairScarJob, args: [ 99 ])
      refute IvRepairScarJob.enqueue(99)
      assert_equal :locked_or_cooling, IvRepairScarJob.enqueue_block_reason(99)
    end
  end

  test "enqueue returns false when iv_repair2 key is unset" do
    ENV.delete("USGS_API_HISTORY_IVREPAIR2_KEY")
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      assert_no_enqueued_jobs only: IvRepairScarJob do
        refute IvRepairScarJob.enqueue(99)
      end
      assert_equal :iv_repair2_key_unconfigured, IvRepairScarJob.enqueue_block_reason(99)
    end
  end

  test "enqueue returns false when iv_repair2 circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair2", ttl: 1.minute)
      assert_no_enqueued_jobs only: IvRepairScarJob do
        refute IvRepairScarJob.enqueue(99)
      end
    end
  end

  test "enqueue still works when tip iv_repair circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair", ttl: 1.minute)
      assert IvRepairScarJob.enqueue(199)
      assert_enqueued_with(job: IvRepairScarJob, args: [ 199 ])
    end
  end
end
