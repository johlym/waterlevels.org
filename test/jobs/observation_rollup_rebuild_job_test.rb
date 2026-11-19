require "test_helper"

class ObservationRollupRebuildJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "rebuilds rollup rows and schedules an inventory refresh" do
    Rails.cache.delete(AdminDashboardStats::COUNTERS_ENQUEUE_KEY)
    series = create(:time_series)
    ContinuousObservation.create!(time_series: series, value: 1, observed_at: Time.utc(2026, 8, 3, 12, 0, 0))
    ObservationRollup.update_all(point_count: 5)

    assert_enqueued_jobs 1, only: AdminDashboardCountersJob do
      ObservationRollupRebuildJob.perform_now
    end

    assert_equal 1, ObservationRollup.summary[:continuous][:lifetime]
  end
end
