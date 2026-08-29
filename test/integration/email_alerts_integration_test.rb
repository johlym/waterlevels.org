# frozen_string_literal: true

require "test_helper"

class EmailAlertsIntegrationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @previous = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    @location = create(
      :monitoring_location,
      flood_category: "no_flooding",
      latest_water_level_value: 5.0,
      latest_observed_at: Time.current
    )
  end

  teardown do
    if @previous.nil?
      ENV.delete("ALERTS_ENABLED")
    else
      ENV["ALERTS_ENABLED"] = @previous
    end
  end

  test "signup verify manage flood delivery flow" do
    assert_enqueued_emails 1 do
      post subscriptions_path, params: {
        email: "paddler@example.com",
        monitoring_location_id: @location.id,
        time_zone: "America/Los_Angeles",
        digest_enabled: "1"
      }
    end
    assert_redirected_to subscriptions_path(monitoring_location_id: @location.id)

    subscriber = Subscriber.find_by!(email: "paddler@example.com")
    refute subscriber.verified?
    watch = subscriber.station_watches.find_by!(monitoring_location: @location)
    assert watch.rule_for("flood_category_change")
    assert watch.rule_for("digest")

    subscriber.subscriber_tokens.where(purpose: "verify").delete_all
    raw = subscriber.issue_token!(purpose: "verify", expires_at: 1.day.from_now)

    get subscriptions_verify_path(token: raw)
    assert_response :redirect
    subscriber.reload
    assert subscriber.verified?

    manage = subscriber.manage_token!
    get subscriptions_manage_path(token: manage)
    assert_response :success
    assert_match(/Alert preferences/, response.body)
    assert_match(/paddler@example.com/, response.body)
    assert_match(@location.display_name, response.body)

    event = AlertEventRecorder.flood_category_change!(
      location: @location,
      from: "no_flooding",
      to: "major",
      observed_at: Time.current
    )
    assert event

    perform_enqueued_jobs only: AlertEvaluationJob
    delivery = AlertDelivery.find_by(subscriber: subscriber, mailer_action: "flood_category_change")
    assert delivery, "expected flood delivery to be queued"

    assert_emails 1 do
      perform_enqueued_jobs only: AlertDeliveryJob
    end
    delivery.reload
    assert_equal "sent", delivery.status
  end

  test "subscriptions 404 when alerts disabled" do
    ENV["ALERTS_ENABLED"] = "0"
    get subscriptions_path
    assert_response :not_found
  end
end
