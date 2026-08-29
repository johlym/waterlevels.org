# frozen_string_literal: true

class AlertDeliveryJob < ApplicationJob
  queue_as :notifications

  def perform(delivery_id)
    return unless AlertsConfig.enabled?

    delivery = AlertDelivery.find_by(id: delivery_id)
    return unless delivery
    return if delivery.status == "sent"

    subscriber = delivery.subscriber
    unless subscriber&.active_for_alerts?
      delivery.update!(status: "skipped", metadata: delivery.metadata.merge("reason" => "inactive"))
      return
    end

    # Digests ignore quiet hours; immediate alerts are suppressed.
    if delivery.mailer_action != "daily_digest" && subscriber.in_quiet_hours?
      delivery.update!(status: "skipped", metadata: delivery.metadata.merge("reason" => "quiet_hours"))
      return
    end

    send_mail!(delivery, subscriber)
    delivery.update!(status: "sent", sent_at: Time.current)
  rescue StandardError => e
    delivery&.update!(
      status: "failed",
      metadata: (delivery.metadata || {}).merge("error" => e.message)
    )
    raise
  end

  private

  def send_mail!(delivery, subscriber)
    event = delivery.alert_event
    rule = delivery.alert_rule
    watch = rule&.station_watch
    location = event&.monitoring_location || watch&.monitoring_location
    manage_token = subscriber.manage_token!
    unsubscribe_token = subscriber.issue_token!(purpose: "unsubscribe", expires_at: 2.years.from_now)

    base = {
      subscriber: subscriber,
      station_watch: watch,
      location: location,
      manage_token: manage_token,
      unsubscribe_token: unsubscribe_token,
      alert_delivery: delivery,
      alert_event: event,
      alert_rule: rule
    }

    case delivery.mailer_action
    when "flood_category_change"
      payload = event&.payload || {}
      AlertMailer.with(
        **base,
        from_category: payload["from"],
        to_category: payload["to"],
        observed_at: payload["observed_at"]
      ).flood_category_change.deliver_now
    when "threshold", "threshold_crossed"
      payload = event&.payload || {}
      AlertMailer.with(
        **base,
        parameter: payload["parameter"] || rule&.param("parameter"),
        value: payload["to"],
        op: rule&.param("op"),
        threshold: rule&.param("value"),
        unit: payload["unit"],
        observed_at: payload["observed_at"]
      ).threshold_crossed.deliver_now
    when "rate_of_rise"
      AlertMailer.with(**base).rate_of_rise.deliver_now
    when "in_range"
      AlertMailer.with(**base).in_range.deliver_now
    when "digest", "daily_digest"
      snapshots = delivery.metadata.dig("snapshot", "stations") ||
        delivery.metadata.dig("snapshot", :stations) ||
        []
      AlertMailer.with(**base, snapshots: snapshots).daily_digest.deliver_now
    else
      raise ArgumentError, "unknown mailer_action=#{delivery.mailer_action}"
    end
  end
end
