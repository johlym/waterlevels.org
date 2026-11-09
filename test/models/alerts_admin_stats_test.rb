require "test_helper"

class AlertsAdminStatsTest < ActiveSupport::TestCase
  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
  end

  teardown do
    if @previous_alerts.nil?
      ENV.delete("ALERTS_ENABLED")
    else
      ENV["ALERTS_ENABLED"] = @previous_alerts
    end
  end

  test "counts watches and recent failures for people who can still be mailed" do
    verified = create(:subscriber, :verified)
    paused = create(:subscriber, :paused)
    unsubscribed = create(:subscriber, :unsubscribed)
    unverified = create(:subscriber)
    create(:station_watch, subscriber: verified)
    create(:station_watch, subscriber: paused)
    create(:station_watch, subscriber: unsubscribed)
    create(:station_watch, subscriber: unverified)

    recent_failure = create(:alert_delivery, subscriber: verified, status: "failed")
    recent_failure.update_columns(created_at: 3.days.ago, updated_at: 1.hour.ago)
    stale_failure = create(:alert_delivery, subscriber: verified, status: "failed")
    stale_failure.update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)
    create(:alert_delivery, :sent, subscriber: verified, sent_at: 1.hour.ago)

    stats = AlertsAdminStats.snapshot

    assert_equal 2, stats[:subscribers_verified]
    assert_equal 2, stats[:watches]
    assert_equal 1, stats[:deliveries_failed_24h]
    assert_equal 1, stats[:deliveries_sent_24h]
  end
end
