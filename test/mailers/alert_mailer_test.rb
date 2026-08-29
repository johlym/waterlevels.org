# frozen_string_literal: true

require "test_helper"

class AlertMailerTest < ActionMailer::TestCase
  setup do
    @subscriber = create(:subscriber, :verified, email: "alerts@example.com")
    @location = create(:monitoring_location, name: "Cedar River near Renton")
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    @manage = @subscriber.manage_token!
    @unsub = @subscriber.issue_token!(purpose: "unsubscribe", expires_at: 30.days.from_now)
  end

  test "verify_email" do
    raw = @subscriber.issue_token!(purpose: "verify", expires_at: 48.hours.from_now)
    email = AlertMailer.with(subscriber: @subscriber, token: raw).verify_email

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal [ "alerts@example.com" ], email.to
    assert_match(/Confirm/, email.subject)
    assert_match(%r{/subscriptions/verify/}, email.html_part.body.to_s)
    assert_match(/informational only/i, email.html_part.body.to_s)
  end

  test "manage_link" do
    email = AlertMailer.with(
      subscriber: @subscriber,
      token: @manage,
      manage_token: @manage,
      unsubscribe_token: @unsub
    ).manage_link

    assert_emails 1 do
      email.deliver_now
    end

    assert_match(/preferences/i, email.subject)
    assert_match(%r{/subscriptions/manage/}, email.html_part.body.to_s)
    assert_match(/Unsubscribe from all/i, email.html_part.body.to_s)
  end

  test "flood_category_change" do
    email = AlertMailer.with(
      subscriber: @subscriber,
      station_watch: @watch,
      location: @location,
      from_category: "no_flooding",
      to_category: "minor",
      observed_at: "2026-08-29 12:00 UTC",
      manage_token: @manage,
      unsubscribe_token: @unsub
    ).flood_category_change

    assert_emails 1 do
      email.deliver_now
    end

    body = email.html_part.body.to_s
    assert_match(/minor/, body)
    assert_match(/Unsubscribe from this station/i, body)
    assert_match(%r{/gauges/}, body)
  end

  test "threshold_crossed" do
    email = AlertMailer.with(
      subscriber: @subscriber,
      station_watch: @watch,
      location: @location,
      parameter: "water_level",
      op: "above",
      value: 12.4,
      threshold: 12.0,
      unit: "ft",
      manage_token: @manage,
      unsubscribe_token: @unsub
    ).threshold_crossed

    assert_emails 1 do
      email.deliver_now
    end

    assert_match(/12\.4/, email.html_part.body.to_s)
    assert_match(/above/, email.html_part.body.to_s)
  end

  test "daily_digest" do
    email = AlertMailer.with(
      subscriber: @subscriber,
      snapshots: [
        { name: @location.display_name, flood_category: "action", water_level: "5.2 ft", url: "https://example.com/g" }
      ],
      manage_token: @manage,
      unsubscribe_token: @unsub
    ).daily_digest

    assert_emails 1 do
      email.deliver_now
    end

    assert_match(/digest/i, email.subject)
    assert_match(/5\.2/, email.html_part.body.to_s)
  end
end
