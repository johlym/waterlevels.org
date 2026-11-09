require "test_helper"

class FloodStageSyncLockTest < ActiveSupport::TestCase
  setup do
    FloodStageSyncLock.release!
  end

  teardown do
    FloodStageSyncLock.release!
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

  test "a dead heartbeat can be taken over and a fresh one cannot" do
    redis = Redis.new(**RedisConfig.options)
    redis.set(FloodStageSyncLock::KEY, "job-a|#{3.hours.ago.to_i}")
    assert FloodStageSyncLock.claim!(owner: "job-b")
    assert FloodStageSyncLock.owned_by?("job-b")

    refute FloodStageSyncLock.claim!(owner: "job-c")
    assert FloodStageSyncLock.owned_by?("job-b")
  ensure
    redis&.close
  end
end
