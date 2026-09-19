require "test_helper"

class DailyArchiveExportJobTest < ActiveSupport::TestCase
  setup do
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    AdminDashboardStats.clear_jobs!
    DailyArchive::ExportCheckpoint.clear!
    DailyArchiveExportLock.release!
  end

  teardown do
    AdminDashboardStats.clear_jobs!
    DailyArchive::ExportCheckpoint.clear!
    DailyArchiveExportLock.release!
    Rails.cache = @previous_cache
    DailyArchive.reset_store!
  end

  test "perform records last-done after exporting leftover dailies" do
    series = create(:time_series)
    DailyObservation.create!(time_series: series, observed_on: Date.current - 1, value: 4.2)

    DailyArchiveExportJob.perform_now

    payload = AdminDashboardStats.last_job(:daily_archive_export)
    assert payload[:finished_at]
    assert_equal "complete", payload[:phase]
    assert_equal 1, payload[:series]
    assert_equal 1, payload[:points]
    refute DailyArchiveExportLock.locked?
    assert AdminDashboardStats.new.jobs_section[:last_daily_archive_export_at]
  end

  test "perform records skip when export lock already held" do
    assert DailyArchiveExportLock.claim!

    DailyArchiveExportJob.perform_now

    assert DailyArchiveExportLock.locked?
    payload = AdminDashboardStats.last_job(:daily_archive_export)
    assert payload[:finished_at]
    assert_equal "lock_held", payload[:skip_reason]
  end

  test "perform records skip when archive store is not configured" do
    DailyArchive.singleton_class.class_eval do
      alias_method :__original_configured?, :configured?
      define_method(:configured?) { false }
    end

    DailyArchiveExportJob.perform_now

    payload = AdminDashboardStats.last_job(:daily_archive_export)
    assert payload[:finished_at]
    assert_equal "not_configured", payload[:skip_reason]
  ensure
    DailyArchive.singleton_class.class_eval do
      alias_method :configured?, :__original_configured?
      remove_method :__original_configured?
    end
  end

  test "archive:export_daily rake records admin last-done" do
    series = create(:time_series)
    DailyObservation.create!(time_series: series, observed_on: Date.current - 1, value: 1.5)
    Rails.application.load_tasks
    task = Rake::Task["archive:export_daily"]
    task.reenable

    task.invoke

    payload = AdminDashboardStats.last_job(:daily_archive_export)
    assert payload[:finished_at]
    assert_equal 1, payload[:series]
    assert_equal 1, payload[:points]
  ensure
    task&.reenable
  end

  test "record_finish! writes the admin snapshot used by rake and the job" do
    DailyArchiveExportJob.record_finish!(
      { series: 2, points: 9, daily_deleted: 9, vacuumed: false, vacuum_ms: 0 }
    )

    payload = AdminDashboardStats.last_job(:daily_archive_export)
    assert payload[:finished_at]
    assert_equal 2, payload[:series]
    assert_equal 9, payload[:points]
    assert_equal "complete", payload[:phase]
  end
end
