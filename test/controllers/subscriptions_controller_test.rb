# frozen_string_literal: true

require "test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    @location = create(:monitoring_location)
  end

  teardown do
    if @previous_alerts
      ENV["ALERTS_ENABLED"] = @previous_alerts
    else
      ENV.delete("ALERTS_ENABLED")
    end
  end

  test "returns 404 when alerts disabled" do
    ENV.delete("ALERTS_ENABLED")
    get subscriptions_path
    assert_response :not_found
  end

  test "new renders manage-link landing and enables session" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get subscriptions_path
    assert_response :success
    assert_includes response.body, "Request your manage link"
    assert_includes response.body, ">Manage Email Alerts</a>"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Set-Cookie"].to_s, "_waterlevels_session"
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "new with monitoring_location_id shows signup form" do
    get subscriptions_path, params: { monitoring_location_id: @location.id }
    assert_response :success
    assert_includes response.body, "Get alerts for this station"
    assert_includes response.body, @location.display_name
  end

  test "create signs up unverified subscriber and sends verify email" do
    assert_enqueued_emails 1 do
      post subscriptions_path, params: {
        email: "new.watcher@example.com",
        monitoring_location_id: @location.id,
        time_zone: "America/Los_Angeles",
        digest_enabled: "1"
      }
    end

    assert_redirected_to subscriptions_path(monitoring_location_id: @location.id)
    subscriber = Subscriber.find_by!(email: "new.watcher@example.com")
    assert_not subscriber.verified?
    assert_equal "America/Los_Angeles", subscriber.time_zone
    assert subscriber.station_watches.exists?(monitoring_location_id: @location.id)
    assert_equal 1, subscriber.subscriber_tokens.where(purpose: "verify").count
  end

  test "create for verified subscriber sends manage link" do
    subscriber = create(:subscriber, :verified, email: "verified@example.com")

    assert_enqueued_emails 1 do
      post subscriptions_path, params: {
        email: subscriber.email,
        monitoring_location_id: @location.id,
        time_zone: "America/New_York"
      }
    end

    assert_redirected_to subscriptions_path(monitoring_location_id: @location.id)
    assert subscriber.station_watches.exists?(monitoring_location_id: @location.id)
  end

  test "create updates time zone when existing subscriber provides one" do
    subscriber = create(
      :subscriber,
      :verified,
      email: "tz.update@example.com",
      time_zone: "America/New_York"
    )

    post subscriptions_path, params: {
      email: subscriber.email,
      monitoring_location_id: @location.id,
      time_zone: "America/Los_Angeles"
    }

    assert_redirected_to subscriptions_path(monitoring_location_id: @location.id)
    assert_equal "America/Los_Angeles", subscriber.reload.time_zone
  end

  test "gauge page embeds turnstile when secret is configured" do
    previous_secret = ENV["TURNSTILE_SECRET"]
    previous_site = ENV["TURNSTILE_SITE_KEY"]
    ENV["TURNSTILE_SECRET"] = "test-secret"
    ENV["TURNSTILE_SITE_KEY"] = "test-site-key"

    get gauge_path(state: @location.path_state, site_number_slug: @location.to_param)
    assert_response :success
    assert_includes response.body, "cf-turnstile"
    assert_includes response.body, "challenges.cloudflare.com/turnstile"
  ensure
    if previous_secret
      ENV["TURNSTILE_SECRET"] = previous_secret
    else
      ENV.delete("TURNSTILE_SECRET")
    end
    if previous_site
      ENV["TURNSTILE_SITE_KEY"] = previous_site
    else
      ENV.delete("TURNSTILE_SITE_KEY")
    end
  end

  test "create manage_link intent emails existing subscriber" do
    subscriber = create(:subscriber, :verified, email: "manage.me@example.com")

    assert_enqueued_emails 1 do
      post subscriptions_path, params: {
        intent: "manage_link",
        email: subscriber.email
      }
    end

    assert_redirected_to subscriptions_path
  end
end
