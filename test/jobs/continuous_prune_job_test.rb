require "test_helper"

class ContinuousPruneJobTest < ActiveSupport::TestCase
  setup do
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    AppSetting.delete_all
    AppConfig.bust!
    AdminDashboardStats.clear_jobs!
    DailyArchive::RetentionCheckpoint.clear!
  end

  teardown do
    AdminDashboardStats.clear_jobs!
    DailyArchive::RetentionCheckpoint.clear!
    Rails.cache = @previous_cache
    DailyArchive.reset_store!
    AppSetting.delete_all
    AppConfig.bust!
  end

  test "records last-done after a successful retention pass" do
    ContinuousPruneJob.perform_now

    payload = AdminDashboardStats.last_job(:prune)
    assert payload[:finished_at]
    assert_equal "complete", payload[:phase]
    refute payload[:skip_reason]
    assert AdminDashboardStats.new.jobs_section[:last_prune_at]
  end

  test "records last-done when disabled by admin settings" do
    AppConfig.write!(:continuous_prune_enabled, false)

    ContinuousPruneJob.perform_now

    payload = AdminDashboardStats.last_job(:prune)
    assert payload[:finished_at]
    assert_equal "disabled_by_settings", payload[:skip_reason]
    stats = AdminDashboardStats.new.jobs_section
    assert stats[:last_prune_at]
    assert_equal "disabled_by_settings", stats[:last_prune_skip_reason]
  end
end
