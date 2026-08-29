# frozen_string_literal: true

require "test_helper"

class AlertDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    @subscriber = create(:subscriber)
    @event = create(:alert_event)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @event.monitoring_location)
    @rule = @watch.rule_for("flood_category_change")
    @delivery = create(
      :alert_delivery,
      subscriber: @subscriber,
      alert_event: @event,
      alert_rule: @rule,
      mailer_action: "flood_category_change",
      status: "queued"
    )
  end

  teardown do
    if @previous_alerts
      ENV["ALERTS_ENABLED"] = @previous_alerts
    else
      ENV.delete("ALERTS_ENABLED")
    end
  end

  test "sends mail and marks delivery sent" do
    assert_emails 1 do
      AlertDeliveryJob.perform_now(@delivery.id)
    end
    @delivery.reload
    assert_equal "sent", @delivery.status
    assert_not_nil @delivery.sent_at
  end

  test "skips during quiet hours for immediate alerts" do
    @subscriber.update!(quiet_hours_start_minute: 0, quiet_hours_end_minute: 24 * 60)
    AlertDeliveryJob.perform_now(@delivery.id)
    assert_equal "skipped", @delivery.reload.status
    assert_equal "quiet_hours", @delivery.metadata["reason"]
  end
end
