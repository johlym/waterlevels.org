require "test_helper"

class HistoryBackfillJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "enqueue claims lock before perform_later" do
    assert HistoryBackfillJob.enqueue(99, "7d")
    assert_enqueued_with(job: HistoryBackfillJob, args: [ 99, "7d" ])
    refute HistoryBackfillJob.enqueue(99, "7d")
  end

  test "enqueue returns false when lock is held" do
    assert HistoryBackfillLock.claim!(99)
    assert_no_enqueued_jobs only: HistoryBackfillJob do
      refute HistoryBackfillJob.enqueue(99, "7d")
    end
  end
end
