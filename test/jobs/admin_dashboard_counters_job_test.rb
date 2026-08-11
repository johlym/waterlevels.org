require "test_helper"

class AdminDashboardCountersJobTest < ActiveSupport::TestCase
  setup do
    AdminDashboardStats.bust_backfill_cache!
  end

  test "perform materializes inventory AdminCounter" do
    create(:monitoring_location, state_code: "wa", latest_observed_at: 30.minutes.ago)

    AdminDashboardCountersJob.perform_now

    row = AdminCounter.fetch(AdminDashboardStats::INVENTORY_KEY)
    assert row
    assert_equal 1, row.value
    assert_equal "schedule", row.source
    payload = AdminCounter.payload_for(AdminDashboardStats::INVENTORY_KEY)
    assert_equal 1, payload[:backfill][:station_count]
    assert payload.key?(:measurement_count)
    assert payload.key?(:stale_station_count)
  end
end
