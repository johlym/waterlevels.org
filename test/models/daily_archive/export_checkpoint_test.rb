require "test_helper"

module DailyArchive
  class ExportCheckpointTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      ExportCheckpoint.clear!
    end

    teardown do
      ExportCheckpoint.clear!
      Rails.cache = @previous_cache
    end

    test "resume_or_start reuses matching fingerprint" do
      first = ExportCheckpoint.resume_or_start!(only_cold: true, time_series_ids: [ 1, 2 ])
      first.mark_series!(10, exported_points: 4, exported_series: 1)
      refute first.resumed

      second = ExportCheckpoint.resume_or_start!(only_cold: true, time_series_ids: [ 2, 1 ])
      assert second.resumed
      assert_equal 10, second.after_series_id
      assert_equal 1, second.series
      assert_equal 4, second.points
    end

    test "resume_or_start starts fresh when fingerprint changes" do
      ExportCheckpoint.resume_or_start!(only_cold: false).mark_series!(5, exported_points: 1, exported_series: 1)
      fresh = ExportCheckpoint.resume_or_start!(only_cold: true)
      refute fresh.resumed
      assert_equal 0, fresh.after_series_id
    end
  end
end
