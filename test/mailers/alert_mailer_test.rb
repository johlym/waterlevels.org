# frozen_string_literal: true

require "test_helper"

class AlertMailerTest < ActionMailer::TestCase
  include MailerHtmlAssertions
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

  test "subscription_confirmation for unverified signup includes confirm, undo, and manage" do
    raw_verify = @subscriber.issue_token!(purpose: "verify", expires_at: 48.hours.from_now)
    email = AlertMailer.with(
      subscriber: @subscriber,
      token: raw_verify,
      manage_token: @manage,
      unsubscribe_token: @unsub,
      station_watch: @watch,
      location: @location
    ).subscription_confirmation

    assert_emails 1 do
      email.deliver_now
    end

    html = email.html_part.body.to_s
    assert_match(/Confirm your subscription/, email.subject)
    assert_match(/Cedar River/, email.subject)
    assert_match(%r{/subscriptions/verify/}, html)
    assert_match(/Undo this subscription/i, html)
    assert_match(%r{/subscriptions/unsubscribe/}, html)
    assert_match(/manage all of your alerts/i, html)
    assert_match(%r{/subscriptions/manage/}, html)
    assert_match(%r{/gauges/}, html)
  end

  test "subscription_confirmation for verified signup highlights undo not manage-only" do
    email = AlertMailer.with(
      subscriber: @subscriber,
      manage_token: @manage,
      unsubscribe_token: @unsub,
      station_watch: @watch,
      location: @location
    ).subscription_confirmation

    html = email.html_part.body.to_s
    assert_match(/You’re subscribed/, email.subject)
    assert_no_match(%r{/subscriptions/verify/}, html)
    assert_match(/Undo this subscription/i, html)
    assert_match(/manage all of your alerts/i, html)
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
    assert_match(%r{<a href="[^"]+/gauges/[^"]+"[^>]*>[^<]*Cedar River}, body)
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

    body = email.html_part.body.to_s
    assert_match(/12\.4/, body)
    assert_match(/above/, body)
    assert_match(%r{<a href="[^"]+/gauges/[^"]+"[^>]*>[^<]*Cedar River}, body)
  end

  test "daily_digest links station names and soft-breaks site numbers" do
    site = @location.site_number
    url = "https://example.com/gauges/wa/#{@location.to_param}"
    email = AlertMailer.with(
      subscriber: @subscriber,
      snapshots: [
        {
          name: @location.display_name,
          site_number: site,
          flood_category: "action",
          water_level: "5.2",
          water_level_unit: "ft",
          discharge: "120",
          discharge_unit: "ft3/s",
          url: url
        }
      ],
      manage_token: @manage,
      unsubscribe_token: @unsub
    ).daily_digest

    assert_emails 1 do
      email.deliver_now
    end

    html = email.html_part.body.to_s
    text = email.text_part.body.to_s
    assert_match(/digest/i, email.subject)
    assert_match(/5\.2/, html)
    assert_match(%r{<a href="#{Regexp.escape(url)}"[^>]*>[^<]*Cedar River}, html)
    assert_no_match(/Open station/i, html)
    # Readings first, flood status last.
    assert_match(/gage height:.*discharge:.*flood:/m, html)
    assert_match(/gage height:.*discharge:.*flood:/m, text)
    # Zero-width spaces break phone auto-linking; contiguous digit run must not appear.
    assert_includes html, "\u200B"
    assert_no_match(/\(#{Regexp.escape(site)}\)/, html)
    assert_match(/site #{Regexp.escape(site)}/, text)
    assert_match(url, text)
  end

  test "html templates are self-contained and use shared mailer styles" do
    raw = @subscriber.issue_token!(purpose: "verify", expires_at: 48.hours.from_now)
    emails = [
      AlertMailer.with(subscriber: @subscriber, token: raw).verify_email,
      AlertMailer.with(
        subscriber: @subscriber,
        token: raw,
        manage_token: @manage,
        unsubscribe_token: @unsub,
        station_watch: @watch,
        location: @location
      ).subscription_confirmation,
      AlertMailer.with(
        subscriber: @subscriber,
        token: @manage,
        manage_token: @manage,
        unsubscribe_token: @unsub
      ).manage_link,
      AlertMailer.with(
        subscriber: @subscriber,
        station_watch: @watch,
        location: @location,
        from_category: "no_flooding",
        to_category: "minor",
        observed_at: "2026-08-29 12:00 UTC",
        manage_token: @manage,
        unsubscribe_token: @unsub
      ).flood_category_change,
      AlertMailer.with(
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
      ).threshold_crossed,
      AlertMailer.with(
        subscriber: @subscriber,
        snapshots: [
          {
            name: @location.display_name,
            site_number: @location.site_number,
            flood_category: "action",
            water_level: "5.2 ft",
            url: "https://example.com/g"
          }
        ],
        manage_token: @manage,
        unsubscribe_token: @unsub
      ).daily_digest
    ]

    emails.each do |email|
      html = email.html_part.body.to_s
      assert_self_contained_mailer_html!(html)
      assert_match(/font-family: -apple-system/, html)
      assert_match(/\.muted \{/, html)
      assert_match(/color: #0891b2/, html)
      assert_match(/format-detection/, html)
      assert_match(/telephone=no/, html)
      # Instruct Bento not to inject open pixels / rewrite links (see mailer layout).
      assert_match(/disable_open/, html)
      assert_match(/disable_click/, html)
      assert_match(/disable_utms/, html)
      # Prefer a hidden element over an HTML comment so Bento Liquid cannot leave "-->".
      assert_match(/bento-flags/, html)
      assert_no_match(/<!--\s*\{\{\s*"true"\s*\|\s*disable_/, html)
      assert_no_match(/-->/, html)
      assert_no_match(/BEGIN app\/views/, html)
    end
  end
end
