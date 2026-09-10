require "test_helper"

class LatestObservationSyncLockTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "claim is exclusive until release" do
    assert LatestObservationSyncLock.claim!
    refute LatestObservationSyncLock.claim!
    assert LatestObservationSyncLock.locked?

    LatestObservationSyncLock.release!
    refute LatestObservationSyncLock.locked?
    assert LatestObservationSyncLock.claim!
  end

  test "sync perform skips when lock already held" do
    assert LatestObservationSyncLock.claim!

    ran = false
    sync = LatestObservationSync.new(progress: SyncProgress.new("latest", io: StringIO.new, logger: nil))
    sync.define_singleton_method(:perform_locked) { ran = true }

    assert_equal false, sync.perform
    refute ran
    assert LatestObservationSyncLock.locked?
  end

  test "sync perform releases the lock after the body finishes" do
    ran = false
    sync = LatestObservationSync.new
    sync.define_singleton_method(:perform_locked) { ran = true }

    sync.perform
    assert ran
    refute LatestObservationSyncLock.locked?
  end

  test "sync perform releases the lock when the body raises" do
    sync = LatestObservationSync.new
    sync.define_singleton_method(:perform_locked) { raise "latest boom" }

    error = assert_raises(RuntimeError) { sync.perform }
    assert_equal "latest boom", error.message
    refute LatestObservationSyncLock.locked?
  end
end
