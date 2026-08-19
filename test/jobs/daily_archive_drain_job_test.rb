require "test_helper"

class DailyArchiveDrainJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    AppSetting.delete_all
    AppConfig.bust!
    @series = create(:time_series)
    @day = Date.current - 1
  end

  teardown do
    Rails.cache = @previous_cache
    DailyArchive.reset_store!
    ENV.delete("DAILY_ARCHIVE_PRUNE")
    AppSetting.delete_all
    AppConfig.bust!
  end

  test "drains leftover postgres dailies already in the archive" do
    ENV["DAILY_ARCHIVE_PRUNE"] = "1"
    AppConfig.bust!
    DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => @day.iso8601, "v" => 3.0, "s" => "usgs" } ]
    )

    DailyArchiveDrainJob.perform_now

    assert_nil DailyObservation.find_by(time_series_id: @series.id, observed_on: @day)
    payload = AdminDashboardStats.last_job(:daily_archive_drain)
    assert_equal 1, payload[:daily_deleted]
    assert_equal 0, payload[:daily_blocked]
  end

  test "skips when prune is disabled" do
    DailyObservation.create!(time_series: @series, observed_on: @day, value: 3.0)
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => @day.iso8601, "v" => 3.0, "s" => "usgs" } ]
    )

    assert_nil DailyArchiveDrainJob.perform_now
    assert DailyObservation.exists?(time_series_id: @series.id, observed_on: @day)
    assert_nil AdminDashboardStats.last_job(:daily_archive_drain)
  end
end
