require "test_helper"

class DailyArchiveExportJobTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    DailyArchive.singleton_class.class_eval do
      alias_method :__original_configured?, :configured?
      define_method(:configured?) { true }
    end
  end

  teardown do
    DailyArchive.singleton_class.class_eval do
      alias_method :configured?, :__original_configured?
      remove_method :__original_configured?
    end
    Rails.cache = @previous_cache
  end

  test "perform skips when export lock already held" do
    assert DailyArchiveExportLock.claim!

    DailyArchiveExportJob.perform_now

    assert DailyArchiveExportLock.locked?
  end
end
