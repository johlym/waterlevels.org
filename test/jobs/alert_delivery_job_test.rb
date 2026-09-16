# frozen_string_literal: true

require "test_helper"

class AlertDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    @subscriber = create(:subscriber, :verified)
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

  test "daily digest ignores quiet hours" do
    @subscriber.update!(quiet_hours_start_minute: 0, quiet_hours_end_minute: 24 * 60)
    digest = create(
      :alert_delivery,
      subscriber: @subscriber,
      mailer_action: "daily_digest",
      status: "queued",
      metadata: { "snapshot" => { "stations" => [] } }
    )
    assert_emails 1 do
      AlertDeliveryJob.perform_now(digest.id)
    end
    assert_equal "sent", digest.reload.status
  end

  test "sends quiet_station mail" do
    delivery = create(
      :alert_delivery,
      subscriber: @subscriber,
      alert_event: create(:alert_event, monitoring_location: @event.monitoring_location),
      alert_rule: @rule,
      mailer_action: "quiet_station",
      status: "queued"
    )
    assert_emails 1 do
      AlertDeliveryJob.perform_now(delivery.id)
    end
    assert_equal "sent", delivery.reload.status
  end

  test "reuses the same manage token across deliveries" do
    first = @subscriber.manage_token!
    AlertDeliveryJob.perform_now(@delivery.id)
    second = @subscriber.manage_token!
    assert_equal first, second
  end

  test "marks digest sent only after a successful send" do
    digest = create(
      :alert_delivery,
      subscriber: @subscriber,
      mailer_action: "daily_digest",
      status: "queued",
      metadata: { "snapshot" => { "stations" => [] } }
    )
    assert_nil @subscriber.digest_last_sent_on
    AlertDeliveryJob.perform_now(digest.id)
    assert_not_nil @subscriber.reload.digest_last_sent_on
  end

  test "does not silently drop a delivery still marked sending" do
    @delivery.update_columns(status: "sending", updated_at: Time.current)

    assert_emails 0 do
      AlertDeliveryJob.perform_now(@delivery.id)
    end

    assert_equal "sending", @delivery.reload.status
    assert_not_equal "sent", @delivery.status
  end

  test "reclaims a stale sending delivery and sends" do
    @delivery.update_columns(status: "sending", updated_at: 11.minutes.ago)

    assert_emails 1 do
      AlertDeliveryJob.perform_now(@delivery.id)
    end

    assert_equal "sent", @delivery.reload.status
    assert_not_nil @delivery.sent_at
  end

  test "leaves an already-sent delivery untouched" do
    @delivery.update!(status: "sent", sent_at: Time.current)

    assert_emails 0 do
      AlertDeliveryJob.perform_now(@delivery.id)
    end

    assert_equal "sent", @delivery.reload.status
  end
end
