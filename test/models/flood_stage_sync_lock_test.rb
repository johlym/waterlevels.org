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

  test "release with an owner leaves another owner's slot in place" do
    assert FloodStageSyncLock.claim!(owner: "job-a")
    refute FloodStageSyncLock.release!(owner: "job-b")
    assert FloodStageSyncLock.owned_by?("job-a")
    refute FloodStageSyncLock.claim!(owner: "job-b")

    assert FloodStageSyncLock.release!(owner: "job-a")
    refute FloodStageSyncLock.locked?
    assert FloodStageSyncLock.claim!(owner: "job-b")
  end

  test "renew extends the owner's slot and refuses a different owner" do
    assert FloodStageSyncLock.claim!(owner: "job-a")
    assert FloodStageSyncLock.renew!("job-a")
    refute FloodStageSyncLock.renew!("job-b")
    assert FloodStageSyncLock.owned_by?("job-a")
  end
end
