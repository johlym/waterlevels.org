require "test_helper"

class BootstrapStateJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "enqueue_bootstrap rake task enqueues staggered state jobs" do
    Rails.application.load_tasks

    task = Rake::Task["usgs:enqueue_bootstrap"]
    task.reenable

    ENV["STATE"] = "wa"
    ENV["DELAY_SECONDS"] = "0"
    begin
      assert_enqueued_with(job: BootstrapStateJob, args: [ "wa" ]) do
        task.invoke
      end
    ensure
      ENV.delete("STATE")
      ENV.delete("DELAY_SECONDS")
      task.reenable
    end
  end

  test "enqueue_sync rake task enqueues a flood stage job for STATE" do
    Rails.application.load_tasks

    task = Rake::Task["nwps:enqueue_sync"]
    task.reenable

    ENV["STATE"] = "tx"
    begin
      assert_enqueued_with(job: FloodStageSyncJob, args: [ "tx" ]) do
        task.invoke
      end
    ensure
      ENV.delete("STATE")
      task.reenable
    end
  end

  test "bootstrap source wires flood stage sync after catalog and latest" do
    source = File.read(Rails.root.join("app/jobs/bootstrap_state_job.rb"))
    catalog_at = source.index("StationCatalogSync")
    latest_at = source.index("LatestObservationSync")
    flood_at = source.index("FloodStageSync")

    assert catalog_at
    assert latest_at
    assert flood_at
    assert_operator catalog_at, :<, latest_at
    assert_operator latest_at, :<, flood_at
  end
end
