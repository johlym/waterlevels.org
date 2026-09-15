# frozen_string_literal: true

class AlertDigestSchedulerJob < ApplicationJob
  queue_as :notifications

  def perform
    return unless AlertsConfig.enabled?

    Subscriber.digest_due.find_each do |subscriber|
      next unless subscriber.due_for_digest?

      snapshot = Alerts::DigestBuilder.new(subscriber).build
      next if snapshot[:stations].blank?

      next if subscriber.alert_deliveries.where(
        mailer_action: "daily_digest",
        status: %w[queued sending]
      ).exists?

      delivery = AlertDelivery.create!(
        subscriber: subscriber,
        mailer_action: "daily_digest",
        status: "queued",
        metadata: { "snapshot" => snapshot }
      )
      AlertDeliveryJob.perform_later(delivery.id)
    end
  end
end
