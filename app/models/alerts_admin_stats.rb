# frozen_string_literal: true

# Lightweight admin metrics for email alerts (Wave 4).
module AlertsAdminStats
  module_function

  def snapshot
    return disabled_snapshot unless AlertsConfig.enabled?

    {
      enabled: true,
      subscribers_verified: Subscriber.verified.where(unsubscribed_at: nil).count,
      subscribers_unsubscribed: Subscriber.where.not(unsubscribed_at: nil).count,
      # Watches belonging to people who can still be mailed. Unsubscribed
      # accounts keep their watch rows, and unverified signups are not live.
      watches: StationWatch.joins(:subscriber).merge(
        Subscriber.verified.where(unsubscribed_at: nil)
      ).count,
      rules_enabled: AlertRule.where(enabled: true).count,
      events_24h: AlertEvent.where(occurred_at: 24.hours.ago..).count,
      deliveries_sent_24h: AlertDelivery.where(status: "sent", sent_at: 24.hours.ago..).count,
      # Failed and skipped are status updates on a row created earlier (often
      # queued). created_at misses a failure that lands after the row is a day old.
      deliveries_failed_24h: AlertDelivery.where(status: "failed", updated_at: 24.hours.ago..).count,
      deliveries_skipped_24h: AlertDelivery.where(status: "skipped", updated_at: 24.hours.ago..).count
    }
  end

  def disabled_snapshot
    {
      enabled: false,
      subscribers_verified: 0,
      subscribers_unsubscribed: 0,
      watches: 0,
      rules_enabled: 0,
      events_24h: 0,
      deliveries_sent_24h: 0,
      deliveries_failed_24h: 0,
      deliveries_skipped_24h: 0
    }
  end
end
