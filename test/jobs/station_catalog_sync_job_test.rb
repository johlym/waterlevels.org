require "test_helper"

class StationCatalogSyncJobTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "perform skips when catalog lock already held" do
    assert StationCatalogSyncLock.claim!

    StationCatalogSyncJob.perform_now

    assert StationCatalogSyncLock.locked?
  end
end
