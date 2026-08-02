require "test_helper"

class HistoryBackfillJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "enqueue claims lock before perform_later" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillJob.enqueue(99, "7d")
      assert_enqueued_with(job: HistoryBackfillJob, args: [ 99, "7d" ])
      refute HistoryBackfillJob.enqueue(99, "7d")
    end
  end

  test "enqueue returns false when lock is held" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillLock.claim!(99)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99, "7d")
      end
    end
  end

  test "enqueue returns false while cooling down" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      HistoryBackfillLock.cooldown!(99)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99, "7d")
      end
    end
  end

  test "enqueue returns false on Sunday for catalog sync budget" do
    travel_to Time.zone.parse("2026-08-02 03:00:00") do # Sunday
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99, "7d")
      end
    end
  end

  test "perform skips USGS calls on Sunday" do
    location = create(:monitoring_location, site_number: "30000098")
    create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-02 15:00:00") do # Sunday
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id, "7d")

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
      refute Rails.cache.exist?("history_backfill:#{location.id}")
      refute HistoryBackfillLock.cooling_down?(location.id)
    end
  end

  test "perform releases lock and cooldowns when history is still missing" do
    location = create(:monitoring_location, site_number: "30000099")
    create(:time_series, monitoring_location: location, selected_for_display: true)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id, "7d")

      refute Rails.cache.exist?("history_backfill:#{location.id}")
      assert HistoryBackfillLock.cooling_down?(location.id)
      refute HistoryBackfillJob.enqueue(location.id, "7d")
    end
  end

  test "perform releases lock without cooldown when continuous data lands" do
    location = create(:monitoring_location, site_number: "30000100")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [
            {
              id: "1",
              properties: {
                time: 1.hour.ago.utc.iso8601,
                value: 3.2,
                approval_status: "Provisional"
              }
            }
          ],
          links: []
        }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id, "7d")

      assert series.continuous_observations.exists?
      refute Rails.cache.exist?("history_backfill:#{location.id}")
      refute HistoryBackfillLock.cooling_down?(location.id)
    end
  end
end
