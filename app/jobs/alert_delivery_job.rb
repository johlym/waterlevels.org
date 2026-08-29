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
    if delivery.mailer_action != "digest" && subscriber.in_quiet_hours?
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
    mailer = AlertMailer.with(
      subscriber: subscriber,
      alert_delivery: delivery,
      alert_event: delivery.alert_event,
      alert_rule: delivery.alert_rule
    )

    case delivery.mailer_action
    when "flood_category_change"
      mailer.flood_category_change.deliver_now
    when "threshold"
      mailer.threshold.deliver_now
    when "rate_of_rise"
      mailer.rate_of_rise.deliver_now
    when "in_range"
      mailer.in_range.deliver_now
    when "digest"
      mailer.digest.deliver_now
    else
      raise ArgumentError, "unknown mailer_action=#{delivery.mailer_action}"
    end
  end
end
