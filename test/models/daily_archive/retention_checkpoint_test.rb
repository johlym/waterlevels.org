require "test_helper"

module DailyArchive
  class RetentionCheckpointTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      RetentionCheckpoint.clear!
      @as_of = Time.utc(2026, 8, 7, 12, 0, 0)
    end

    teardown do
      RetentionCheckpoint.clear!
      Rails.cache = @previous_cache
    end

    test "resume_or_start reuses same-day checkpoint and as_of" do
      first = RetentionCheckpoint.resume_or_start!(as_of: @as_of)
      first.mark_series!(42, usgs_ensured: 3)
      refute first.resumed

      second = RetentionCheckpoint.resume_or_start!(as_of: @as_of + 3.hours)
      assert second.resumed
      assert_equal @as_of, second.as_of
      assert_equal 42, second.after_series_id
      assert_equal 3, second.stats["usgs_ensured"]
    end

    test "resume_or_start discards checkpoint from a different UTC day" do
      stale = RetentionCheckpoint.resume_or_start!(as_of: @as_of)
      stale.mark_series!(99, derived: 1)

      fresh = RetentionCheckpoint.resume_or_start!(as_of: @as_of + 1.day)
      refute fresh.resumed
      assert_equal 0, fresh.after_series_id
      assert_equal 0, fresh.stats["derived"]
    end

    test "complete_phase advances cursor and phase" do
      checkpoint = RetentionCheckpoint.start!(@as_of)
      checkpoint.mark_series!(10, usgs_ensured: 2)
      checkpoint.complete_phase!("handoff", usgs_ensured: 2, derived: 1, retrying: 0)

      assert_equal "iv_prune", checkpoint.phase
      assert_equal 0, checkpoint.after_series_id
      assert checkpoint.phase_completed?("handoff")
      refute checkpoint.phase_completed?("iv_prune")
      assert_equal 2, checkpoint.stats["usgs_ensured"]
      assert_equal 1, checkpoint.stats["derived"]
    end

    test "record_gap persists across resume" do
      checkpoint = RetentionCheckpoint.start!(@as_of)
      checkpoint.record_gap!(7, "2026-06-20")
      checkpoint.complete_phase!("handoff")

      resumed = RetentionCheckpoint.resume_or_start!(as_of: @as_of)
      assert_equal [ [ 7, "2026-06-20" ] ], resumed.gap_days
    end
  end
end
