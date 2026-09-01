# frozen_string_literal: true

require "test_helper"

class AlertEvaluationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    @location = create(:monitoring_location, flood_category: "minor")
    @subscriber = create(:subscriber, :verified)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    @event = create(
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
  end

  test "enqueues delivery for matching flood rule" do
    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertEvaluationJob.perform_now(@location.id)
    end

    delivery = AlertDelivery.last
    assert_equal @subscriber.id, delivery.subscriber_id
    assert_equal @event.id, delivery.alert_event_id
    assert_equal "flood_category_change", delivery.mailer_action
    assert_equal "queued", delivery.status
    assert @watch.rule_for("flood_category_change").reload.last_fired_at.present?
  end

  test "noops when alerts disabled" do
    ENV["ALERTS_ENABLED"] = "0"
    assert_no_difference("AlertDelivery.count") do
      AlertEvaluationJob.perform_now(@location.id)
    end
  end

  test "skips inactive subscribers" do
    @subscriber.update!(paused_at: Time.current)
    assert_no_difference("AlertDelivery.count") do
      AlertEvaluationJob.perform_now(@location.id)
    end
  end

  test "evaluates flood events whose NWPS validTime is older than the pending window" do
    @event.update!(occurred_at: 6.hours.ago)

    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertEvaluationJob.perform_now(@location.id)
    end
    assert_equal @event.id, AlertDelivery.last.alert_event_id
  end

  test "evaluates a targeted event even when it was recorded before the pending window" do
    @event.update_columns(occurred_at: 6.hours.ago, created_at: 3.hours.ago)

    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertEvaluationJob.perform_now(@location.id, @event.id)
    end
    assert_equal @event.id, AlertDelivery.last.alert_event_id
  end
end
