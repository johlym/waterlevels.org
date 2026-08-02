require "test_helper"

class HistoryBackfillBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "enqueues history jobs for locations needing backfill" do
    needs = create(:monitoring_location, site_number: "30000001")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    complete = create(:monitoring_location, site_number: "30000002")
    series = create(:time_series, monitoring_location: complete, selected_for_display: true)
    ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)

    assert_enqueued_with(job: HistoryBackfillJob, args: [ needs.id, "7d" ]) do
      HistoryBackfillBatchJob.perform_now(10, "7d")
    end
  end
end
