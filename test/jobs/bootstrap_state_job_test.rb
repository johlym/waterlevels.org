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
end
