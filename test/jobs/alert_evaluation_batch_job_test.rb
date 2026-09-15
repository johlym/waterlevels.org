# frozen_string_literal: true

require "test_helper"

class AlertEvaluationBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    AlertEvaluationEnqueueBuffer.backend = AlertEvaluationEnqueueBuffer::MemoryBackend.new
    @location = create(:monitoring_location, flood_category: "minor")
    @subscriber = create(:subscriber, :verified)
    create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    create(
      :alert_event,
      monitoring_location: @location,
      kind: "flood_category_change",
      occurred_at: 5.minutes.ago,
      payload: { "from" => "no_flooding", "to" => "minor", "observed_at" => 5.minutes.ago.iso8601 }
    )
  end

  teardown do
    if @previous_alerts
      ENV["ALERTS_ENABLED"] = @previous_alerts
    else
      ENV.delete("ALERTS_ENABLED")
    end
    AlertEvaluationEnqueueBuffer.reset!
  end

  test "drains buffer and evaluates each location once" do
    AlertEvaluationEnqueueBuffer.add(@location.id)
    AlertEvaluationEnqueueBuffer.add(@location.id)

    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertEvaluationBatchJob.perform_now
    end

    assert_empty AlertEvaluationEnqueueBuffer.drain
    assert_equal 1, AlertDelivery.count
  end

  test "re-queues remaining location ids when evaluation fails mid-batch" do
    second = create(:monitoring_location, flood_category: "action")
    first_id = @location.id
    second_id = second.id
    AlertEvaluationEnqueueBuffer.add(first_id)
    AlertEvaluationEnqueueBuffer.add(second_id)

    calls = []
    original = AlertEvaluationJob.method(:perform_now)
    AlertEvaluationJob.define_singleton_method(:perform_now) do |id|
      calls << id
      raise "boom" if id == first_id
    end

    begin
      assert_raises(RuntimeError) { AlertEvaluationBatchJob.perform_now }
    ensure
      AlertEvaluationJob.define_singleton_method(:perform_now, original)
    end

    assert_equal [ first_id ], calls
    remaining = AlertEvaluationEnqueueBuffer.drain
    assert_includes remaining, second_id
    assert_includes remaining, first_id
  end
end
