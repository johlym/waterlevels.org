require "test_helper"

class FloodStageSyncBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "enqueues one flood sync job per state" do
    states = Usgs::StateCodes::STATES.keys.sort

    assert_enqueued_jobs states.size, only: FloodStageSyncJob do
      FloodStageSyncBatchJob.perform_now
    end

    assert_enqueued_with(job: FloodStageSyncJob, args: [ states.first ])
    assert_enqueued_with(job: FloodStageSyncJob, args: [ states.last ])
  end

  test "skips enqueue when prior flood sync jobs are still queued" do
    batch = FloodStageSyncBatchJob.new
    batch.define_singleton_method(:prior_flood_sync_draining?) { true }

    assert_no_enqueued_jobs only: FloodStageSyncJob do
      assert_equal 0, batch.perform
    end
  end
end
