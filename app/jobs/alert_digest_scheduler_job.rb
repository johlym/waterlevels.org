# frozen_string_literal: true

class AlertDigestSchedulerJob < ApplicationJob
  queue_as :notifications

  def perform
    return unless AlertsConfig.enabled?

    Subscriber.digest_due.find_each do |subscriber|
      next unless subscriber.due_for_digest?

      snapshot = Alerts::DigestBuilder.new(subscriber).build
      next if snapshot[:stations].blank?

      delivery = AlertDelivery.create!(
        subscriber: subscriber,
        mailer_action: "digest",
        status: "queued",
        metadata: { "snapshot" => snapshot }
      )
      AlertDeliveryJob.perform_later(delivery.id)
      subscriber.mark_digest_sent!
    end
  end
end
