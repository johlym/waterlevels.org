require "test_helper"

class AppLoggingJobLogSubscriberTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class DemoJob < ApplicationJob
    queue_as :default

    def perform(state = "wa")
      state
    end
  end

  setup do
    @io = StringIO.new
    @logger = ActiveSupport::Logger.new(@io)
    @previous_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = @logger

    ActiveJob::LogSubscriber.detach_from(:active_job)
    AppLogging::JobLogSubscriber.detach_from(:active_job)
    AppLogging::JobLogSubscriber.attach_to :active_job
  end

  teardown do
    AppLogging::JobLogSubscriber.detach_from(:active_job)
    ActiveJob::LogSubscriber.attach_to :active_job
    ActiveJob::Base.logger = @previous_logger
  end

  test "perform logs a single structured lifecycle line" do
    perform_enqueued_jobs { DemoJob.perform_later("wa") }

    lines = @io.string.lines.map(&:strip).reject(&:blank?)
    perform_line = lines.find { |line| line.include?("event=job.perform") }

    assert perform_line, "expected a job.perform line, got: #{lines.inspect}"
    assert_includes perform_line, "job=AppLoggingJobLogSubscriberTest::DemoJob"
    assert_includes perform_line, "queue=default"
    assert_includes perform_line, "status=ok"
    assert_match(/duration=\d+\.\d+/, perform_line)
    assert_includes perform_line, 'args=["wa"]'
    refute lines.any? { |line| line.include?("Performing ") || line.include?("Performed ") }
  end

  test "enqueue logs structured line without perform_start noise" do
    DemoJob.perform_later("or")

    lines = @io.string.lines.map(&:strip).reject(&:blank?)
    enqueue_line = lines.find { |line| line.include?("event=job.enqueue") }

    assert enqueue_line, "expected a job.enqueue line, got: #{lines.inspect}"
    assert_includes enqueue_line, "status=ok"
    assert_includes enqueue_line, 'args=["or"]'
    refute lines.any? { |line| line.include?("Performing ") }
  end
end
