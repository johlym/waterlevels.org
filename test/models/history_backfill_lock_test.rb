require "test_helper"

class HistoryBackfillLockTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "claim succeeds once until released" do
    assert HistoryBackfillLock.claim!(1)
    refute HistoryBackfillLock.claim!(1)
    HistoryBackfillLock.release!(1)
    assert HistoryBackfillLock.claim!(1)
  end

  test "claim fails while cooling down" do
    HistoryBackfillLock.cooldown!(2)
    refute HistoryBackfillLock.claim!(2)
    HistoryBackfillLock.clear!(2)
    assert HistoryBackfillLock.claim!(2)
  end

  test "locked? reflects an active claim" do
    refute HistoryBackfillLock.locked?(3)
    assert HistoryBackfillLock.claim!(3)
    assert HistoryBackfillLock.locked?(3)
    HistoryBackfillLock.release!(3)
    refute HistoryBackfillLock.locked?(3)
  end
end

