require "test_helper"

class StationCatalogSyncLockTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "claim is exclusive until release" do
    assert StationCatalogSyncLock.claim!
    refute StationCatalogSyncLock.claim!
    assert StationCatalogSyncLock.locked?

    StationCatalogSyncLock.release!
    refute StationCatalogSyncLock.locked?
    assert StationCatalogSyncLock.claim!
  end

  test "sync perform skips when lock already held" do
    assert StationCatalogSyncLock.claim!

    ran = false
    sync = StationCatalogSync.new(progress: SyncProgress.new("catalog", io: StringIO.new, logger: nil))
    sync.define_singleton_method(:perform_body) { ran = true }

    assert_equal false, sync.perform
    refute ran
    assert StationCatalogSyncLock.locked?
  end

  test "sync perform releases the lock after the body finishes" do
    ran = false
    sync = StationCatalogSync.new
    sync.define_singleton_method(:perform_body) { ran = true }

    sync.perform
    assert ran
    refute StationCatalogSyncLock.locked?
  end

  test "sync perform releases the lock when the body raises" do
    sync = StationCatalogSync.new
    sync.define_singleton_method(:perform_body) { raise "catalog boom" }

    error = assert_raises(RuntimeError) { sync.perform }
    assert_equal "catalog boom", error.message
    refute StationCatalogSyncLock.locked?
  end
end
