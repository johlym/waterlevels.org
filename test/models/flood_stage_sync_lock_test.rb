require "test_helper"

class FloodStageSyncLockTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "claim is exclusive until release" do
    assert FloodStageSyncLock.claim!
    refute FloodStageSyncLock.claim!
    assert FloodStageSyncLock.locked?

    FloodStageSyncLock.release!
    refute FloodStageSyncLock.locked?
    assert FloodStageSyncLock.claim!
  end
end
