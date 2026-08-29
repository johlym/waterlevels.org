# frozen_string_literal: true

# Soft-suppress subscribers after Bento bounce/complaint webhooks (Wave 4 stub).
# Wire a controller later; for now ops can call suppress!.
class AlertBounceHandler
  def self.suppress!(email:, reason: "bounce")
    subscriber = Subscriber.find_by(email: email.to_s.strip.downcase)
    return if subscriber.nil?

    subscriber.unsubscribe_all!
    subscriber.alert_deliveries.create!(
      mailer_action: "bounce_suppression",
      status: "skipped",
      metadata: { "reason" => reason.to_s, "at" => Time.current.iso8601 }
    )
    subscriber
  end
end
