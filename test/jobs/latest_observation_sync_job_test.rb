require "test_helper"

class LatestObservationSyncJobTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "perform skips when latest lock already held" do
    assert LatestObservationSyncLock.claim!

    LatestObservationSyncJob.perform_now

    assert LatestObservationSyncLock.locked?
  end
end
