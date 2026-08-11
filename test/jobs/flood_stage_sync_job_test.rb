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

  test "pads short state cycles to 30s" do
    slept = nil
    job = FloodStageSyncJob.new
    job.define_singleton_method(:sleep_for_pacing) { |seconds| slept = seconds }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0
    progress = SyncProgress.new("test", io: nil, logger: nil)
    job.send(:pad_to_min_cycle!, started, progress, label: "wa")

    assert_in_delta 25.0, slept, 1.0
  end

  test "skips pacing sleep when a state already exceeded 30s" do
    slept = :not_called
    job = FloodStageSyncJob.new
    job.define_singleton_method(:sleep_for_pacing) { |seconds| slept = seconds }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 40.0
    progress = SyncProgress.new("test", io: nil, logger: nil)
    job.send(:pad_to_min_cycle!, started, progress, label: "wa")

    assert_equal :not_called, slept
  end

  test "single-state perform syncs that state and pads" do
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
    assert_operator slept, :<=, FloodStageSyncJob::MIN_STATE_SECONDS
  end

  test "national perform loops states with pacing between each" do
    paced = []
    synced = []

    job = FloodStageSyncJob.new
    job.define_singleton_method(:states_to_sync) { %w[ak al] }
    job.define_singleton_method(:sleep_for_pacing) { |seconds| paced << seconds }
    job.define_singleton_method(:run_state_sync) { |code, _progress| synced << code }

    job.perform

    assert_equal %w[ak al], synced
    assert_equal 2, paced.size
    paced.each do |seconds|
      assert_operator seconds, :>, 0
      assert_operator seconds, :<=, FloodStageSyncJob::MIN_STATE_SECONDS
    end
  end

  test "national perform skips when lock already held" do
    assert FloodStageSyncLock.claim!

    synced = 0
    job = FloodStageSyncJob.new
    job.define_singleton_method(:states_to_sync) { %w[ak] }
    job.define_singleton_method(:run_state_sync) { |*_args| synced += 1 }
    job.define_singleton_method(:sleep_for_pacing) { |_seconds| nil }
    job.perform

    assert_equal 0, synced
  end

  test "legacy no-arg perform runs the national loop" do
    synced = []
    job = FloodStageSyncJob.new
    job.define_singleton_method(:states_to_sync) { %w[tx] }
    job.define_singleton_method(:run_state_sync) { |code, _progress| synced << code }
    job.define_singleton_method(:sleep_for_pacing) { |_seconds| nil }
    job.perform

    assert_equal %w[tx], synced
  end
end
