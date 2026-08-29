# frozen_string_literal: true

require "test_helper"

module Subscriptions
  class VerificationsControllerTest < ActionDispatch::IntegrationTest
    include ActionMailer::TestHelper

    setup do
      @previous_alerts = ENV["ALERTS_ENABLED"]
      ENV["ALERTS_ENABLED"] = "1"
    end

    teardown do
      if @previous_alerts
        ENV["ALERTS_ENABLED"] = @previous_alerts
      else
        ENV.delete("ALERTS_ENABLED")
      end
    end

    test "verify confirms subscriber and redirects to manage" do
      subscriber = create(:subscriber, email: "to.verify@example.com")
      location = create(:monitoring_location)
      create(:station_watch, subscriber: subscriber, monitoring_location: location)
      raw = subscriber.issue_token!(purpose: "verify", expires_at: 48.hours.from_now)

      assert_enqueued_emails 1 do
        get subscriptions_verify_path(token: raw)
      end

      assert subscriber.reload.verified?
      assert_response :redirect
      assert_match %r{/subscriptions/manage/}, response.redirect_url
    end

    test "invalid verify token redirects with alert" do
      get subscriptions_verify_path(token: "not-a-real-token")
      assert_redirected_to subscriptions_path
    end
  end
end
