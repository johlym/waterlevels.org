# frozen_string_literal: true

class AlertDigestSchedulerJob < ApplicationJob
  queue_as :notifications

  def perform
    return unless AlertsConfig.enabled?

    # Recover deliveries left in `sending` after a worker crash. Immediate
    # Sidekiq redelivery hits AlertDeliveryJob::InProgress; this sweep covers
    # jobs that were ACKed after a successful no-op (pre-fix) or exhausted
    # retries, so flood/digest mail is not stuck forever.
    AlertDeliveryJob.requeue_stale_sending!

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
