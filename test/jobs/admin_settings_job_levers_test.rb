require "test_helper"

class AdminSettingsJobLeversTest < ActiveSupport::TestCase
  setup do
    AppSetting.delete_all
    AppConfig.bust!
  end

  test "LatestObservationSyncJob skips when disabled" do
    AppConfig.write!(:latest_observation_sync_enabled, false)
    # Early return before USGS/network work.
    assert_nil LatestObservationSyncJob.perform_now("wa")
  end

  test "HistoryBackfillBatchJob skips when disabled" do
    AppConfig.write!(:history_backfill_enabled, false)
    assert_equal 0, HistoryBackfillBatchJob.perform_now
  end

  test "Sunday pause respects admin lever" do
    sunday = Time.utc(2026, 8, 9, 12) # Sunday
    assert HistoryBackfillJob.paused_for_catalog_sync?(sunday)

    AppConfig.write!(:sunday_catalog_pause_enabled, false)
    refute HistoryBackfillJob.paused_for_catalog_sync?(sunday)
  end

  test "IvRepairJob enqueue blocked when disabled" do
    AppConfig.write!(:iv_repair_enabled, false)
    location = create(:monitoring_location)
    assert_equal :disabled_by_settings, IvRepairJob.enqueue_block_reason(location.id)
  end
end
