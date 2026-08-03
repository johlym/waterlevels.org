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
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert_enqueued_with(job: HistoryBackfillJob, args: [ needs.id, "1y" ]) do
        HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end

  test "skips cooling stations and advances to later candidates" do
    stuck = create(:monitoring_location, site_number: "30000010")
    create(:time_series, monitoring_location: stuck, selected_for_display: true)

    ready = create(:monitoring_location, site_number: "30000011")
    create(:time_series, monitoring_location: ready, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      HistoryBackfillLock.cooldown!(stuck.id)

      assert_enqueued_with(job: HistoryBackfillJob, args: [ ready.id, "1y" ]) do
        assert_equal 1, HistoryBackfillBatchJob.perform_now(1)
      end
      refute HistoryBackfillJob.enqueue(stuck.id)
    end
  end

  test "skips enqueueing on Sunday for catalog sync budget" do
    needs = create(:monitoring_location, site_number: "30000020")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end

  test "skips enqueueing when USGS rate limit circuit is open" do
    needs = create(:monitoring_location, site_number: "30000021")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(ttl: 1.minute)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end
end
