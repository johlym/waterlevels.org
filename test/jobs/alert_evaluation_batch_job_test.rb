# frozen_string_literal: true

require "test_helper"

class AlertEvaluationBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    AlertEvaluationEnqueueBuffer.backend = AlertEvaluationEnqueueBuffer::MemoryBackend.new
    clear_enqueued_jobs
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

  test "evaluates each buffered location once and clears the buffer" do
    AlertEvaluationEnqueueBuffer.add(@location.id)
    AlertEvaluationEnqueueBuffer.add(@location.id)

    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertEvaluationBatchJob.perform_now
    end

    assert_empty AlertEvaluationEnqueueBuffer.members
    refute AlertEvaluationEnqueueBuffer.any?
    assert_equal 1, AlertDelivery.count
  end

  test "keeps evaluating other locations when one evaluation raises" do
    other = create(:monitoring_location, flood_category: "moderate")
    create(:station_watch, subscriber: @subscriber, monitoring_location: other)
    create(
      :alert_event,
      monitoring_location: other,
      kind: "flood_category_change",
      occurred_at: 5.minutes.ago,
      payload: { "from" => "no_flooding", "to" => "moderate", "observed_at" => 5.minutes.ago.iso8601 }
    )

    AlertEvaluationEnqueueBuffer.add(@location.id)
    AlertEvaluationEnqueueBuffer.add(other.id)

    failing_id = @location.id
    with_evaluation_override(->(id) {
      raise StandardError, "eval failed" if id == failing_id

      AlertEvaluationJob.new.perform(id)
    }) do
      AlertEvaluationBatchJob.perform_now
    end

    assert_includes AlertEvaluationEnqueueBuffer.members, @location.id
    refute_includes AlertEvaluationEnqueueBuffer.members, other.id
    assert_equal 1, AlertDelivery.count
    assert_equal other.id, AlertDelivery.last.alert_event.monitoring_location_id
    assert_enqueued_with(job: AlertEvaluationBatchJob)
  end

  test "reschedules flush for ids added while a batch is running" do
    late = create(:monitoring_location)
    AlertEvaluationEnqueueBuffer.add(@location.id)

    late_id = late.id
    with_evaluation_override(->(id) {
      AlertEvaluationEnqueueBuffer.add(late_id)
      AlertEvaluationJob.new.perform(id)
    }) do
      AlertEvaluationBatchJob.perform_now
    end

    assert_includes AlertEvaluationEnqueueBuffer.members, late.id
    refute_includes AlertEvaluationEnqueueBuffer.members, @location.id
    assert_enqueued_with(job: AlertEvaluationBatchJob)
  end

  private

  def with_evaluation_override(callable)
    singleton = class << AlertEvaluationJob; self; end
    singleton.alias_method :__original_perform_now, :perform_now
    singleton.define_method(:perform_now) { |id| callable.call(id) }
    yield
  ensure
    singleton.alias_method :perform_now, :__original_perform_now
    singleton.remove_method :__original_perform_now
  end
end
