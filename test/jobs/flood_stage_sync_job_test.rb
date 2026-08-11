require "test_helper"

class FloodStageSyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "requires a state" do
    error = assert_raises(ArgumentError) { FloodStageSyncJob.perform_now(nil) }
    assert_match(/requires a state/, error.message)
  end

  test "requeues when another flood sync holds the lock" do
    assert FloodStageSyncLock.claim!

    assert_enqueued_with(
      job: FloodStageSyncJob,
      args: [ "wa" ],
      at: (Time.current + FloodStageSyncJob::LOCK_BUSY_REQUEUE_SECONDS.seconds)
    ) do
      FloodStageSyncJob.perform_now("wa")
    end
  end

  test "pads short runs to the 31s min cycle" do
    slept = nil
    job = FloodStageSyncJob.new
    job.define_singleton_method(:sleep_for_pacing) { |seconds| slept = seconds }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0
    progress = SyncProgress.new("test", io: nil, logger: nil)
    job.send(:pad_to_min_cycle!, started, progress)

    assert_in_delta 26.0, slept, 1.0
  end

  test "skips pacing sleep when work already exceeded 31s" do
    slept = :not_called
    job = FloodStageSyncJob.new
    job.define_singleton_method(:sleep_for_pacing) { |seconds| slept = seconds }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 40.0
    progress = SyncProgress.new("test", io: nil, logger: nil)
    job.send(:pad_to_min_cycle!, started, progress)

    assert_equal :not_called, slept
  end

  test "runs flood sync for the given state and pads afterward" do
    create(
      :monitoring_location,
      site_number: "01646500",
      usgs_monitoring_location_id: "USGS-01646500",
      state_code: "wa",
      nwps_lid: "BRKM2",
      nwps_matched: true,
      nwps_synced_at: 1.hour.ago,
      flood_category: "no_flooding"
    )

    stub_request(:get, %r{\Ahttps://api\.water\.noaa\.gov/nwps/v1/gauges\?})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          gauges: [
            {
              lid: "BRKM2",
              state: { abbreviation: "WA" },
              status: {
                observed: { floodCategory: "no_flooding", validTime: "2026-08-03T04:15:00Z" }
              }
            }
          ]
        }.to_json
      )

    slept = nil
    job = FloodStageSyncJob.new
    job.define_singleton_method(:sleep_for_pacing) { |seconds| slept = seconds }
    job.perform("WA")

    assert_operator slept, :>, 0
    assert_operator slept, :<=, FloodStageSyncJob::MIN_CYCLE_SECONDS
  end
end
