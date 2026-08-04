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

  test "enqueue claims lock before perform_later with 1y default" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillJob.enqueue(99)
      assert_enqueued_with(job: HistoryBackfillJob, args: [ 99, "1y" ])
      refute HistoryBackfillJob.enqueue(99)
    end
  end

  test "enqueue returns false when lock is held" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillLock.claim!(99)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99)
      end
    end
  end

  test "enqueue returns false while cooling down" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      HistoryBackfillLock.cooldown!(99)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99)
      end
    end
  end

  test "enqueue returns false on Sunday for catalog sync budget" do
    travel_to Time.zone.parse("2026-08-02 03:00:00") do # Sunday
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99)
      end
    end
  end

  test "enqueue returns false when USGS rate limit circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(ttl: 1.minute)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99)
      end
    end
  end

  test "enqueue returns false when database read-only circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      DatabaseReadOnlyCircuit.open!(ttl: 1.minute)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        refute HistoryBackfillJob.enqueue(99)
      end
    end
  end

  test "perform skips USGS calls when rate limit circuit is open" do
    location = create(:monitoring_location, site_number: "30000097")
    create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(ttl: 1.minute)
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id)

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
      refute Rails.cache.exist?("history_backfill:#{location.id}")
    end
  end

  test "perform does not cooldown when database is read-only" do
    location = create(:monitoring_location, site_number: "30000096")
    create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      DatabaseReadOnlyCircuit.open!(ttl: 1.minute)
      assert HistoryBackfillLock.claim!(location.id)

      assert_enqueued_with(job: HistoryBackfillJob) do
        HistoryBackfillJob.perform_now(location.id)
      end

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
      refute Rails.cache.exist?("history_backfill:#{location.id}")
      refute HistoryBackfillLock.cooling_down?(location.id)
    end
  end

  test "perform skips USGS calls on Sunday" do
    location = create(:monitoring_location, site_number: "30000098")
    create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-02 15:00:00") do # Sunday
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id)

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
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id)

      refute Rails.cache.exist?("history_backfill:#{location.id}")
      assert HistoryBackfillLock.cooling_down?(location.id)
      refute HistoryBackfillJob.enqueue(location.id)
    end
  end

  test "perform releases lock without cooldown when continuous and daily history land" do
    location = create(:monitoring_location, site_number: "30000100")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "1",
                properties: {
                  time_series_id: series.usgs_time_series_id,
                  parameter_code: series.parameter_code,
                  time: 1.hour.ago.utc.iso8601,
                  value: 3.2,
                  approval_status: "Provisional"
                }
              }
            ],
            links: []
          }.to_json
        )
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "d1",
                properties: {
                  time_series_id: series.usgs_time_series_id,
                  parameter_code: series.parameter_code,
                  time: 11.months.ago.to_date.iso8601,
                  value: 2.5,
                  approval_status: "Approved"
                }
              },
              {
                id: "d2",
                properties: {
                  time_series_id: series.usgs_time_series_id,
                  parameter_code: series.parameter_code,
                  time: Date.current.iso8601,
                  value: 2.6,
                  approval_status: "Provisional"
                }
              }
            ],
            links: []
          }.to_json
        )
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id)

      assert series.continuous_observations.exists?
      assert series.daily_observations.exists?
      refute Rails.cache.exist?("history_backfill:#{location.id}")
      refute HistoryBackfillLock.cooling_down?(location.id)
    end
  end

  test "perform cooldowns deep range when 3y daily history is still missing" do
    location = create(:monitoring_location, site_number: "30000101")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
      DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)
      PeakObservation.create!(time_series: series, water_year: 2025, value: 9.0, peak_kind: "high")

      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

      assert HistoryBackfillLock.claim!(location.id)
      HistoryBackfillJob.perform_now(location.id, "3y")

      assert location.missing_deep_history?
      refute Rails.cache.exist?("history_backfill:#{location.id}")
      assert HistoryBackfillLock.cooling_down?(location.id)
    end
  end
end
