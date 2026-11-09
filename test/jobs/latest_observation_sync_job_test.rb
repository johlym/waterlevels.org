require "test_helper"

class LatestObservationSyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    LatestObservationSyncLock.release!
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "enqueue keeps a single tip sync while one is reserved" do
    first = LatestObservationSyncJob.perform_later
    assert_instance_of LatestObservationSyncJob, first
    assert LatestObservationSyncLock.owned_by?(first.job_id)

    assert_no_enqueued_jobs only: LatestObservationSyncJob do
      assert_equal false, LatestObservationSyncJob.perform_later
    end
  end

  test "perform skips when latest lock already held" do
    assert LatestObservationSyncLock.claim!

    LatestObservationSyncJob.perform_now

    assert LatestObservationSyncLock.locked?
  end
end
