require "test_helper"

class IvRepairJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @previous_env = {
      "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"],
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
  end

  teardown do
    Rails.cache = @previous_cache
    @previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "enqueue claims lock before perform_later" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert IvRepairJob.enqueue(99)
      assert_enqueued_with(job: IvRepairJob, args: [ 99 ])
      refute IvRepairJob.enqueue(99)
    end
  end

  test "enqueue returns false on Sunday" do
    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      assert_no_enqueued_jobs only: IvRepairJob do
        refute IvRepairJob.enqueue(99)
      end
    end
  end

  test "enqueue returns false when iv_repair circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair", ttl: 1.minute)
      assert_no_enqueued_jobs only: IvRepairJob do
        refute IvRepairJob.enqueue(99)
      end
    end
  end

  test "enqueue still works when cold history circuits are open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(key_id: "history_continuous", ttl: 1.minute)
      Usgs::RateLimitCircuit.open!(key_id: "history_daily", ttl: 1.minute)
      assert IvRepairJob.enqueue(199)
      assert_enqueued_with(job: IvRepairJob, args: [ 199 ])
    end
  end

  test "perform cools down when still gappy after empty USGS response" do
    location = create(:monitoring_location, site_number: "30000101")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    daily_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
    peaks_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 12.hours.ago
      )
      ContinuousObservation.create!(time_series: series, observed_at: 30.minutes.ago, value: 12.5)

      assert IvRepairLock.claim!(location.id)
      IvRepairJob.perform_now(location.id)

      assert_requested :get, %r{collections/continuous/items}
      assert_not_requested daily_stub
      assert_not_requested peaks_stub
      assert IvRepairLock.cooling_down?(location.id)
      refute IvRepairLock.locked?(location.id)
    end
  end
end
