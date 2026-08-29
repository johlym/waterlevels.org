# frozen_string_literal: true

require "test_helper"

module Subscriptions
  class UnsubscribesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @previous_alerts = ENV["ALERTS_ENABLED"]
      ENV["ALERTS_ENABLED"] = "1"
      @subscriber = create(:subscriber, :verified)
      @raw = @subscriber.issue_token!(purpose: "unsubscribe", expires_at: 30.days.from_now)
      @location = create(:monitoring_location)
      @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    end

    teardown do
      if @previous_alerts
        ENV["ALERTS_ENABLED"] = @previous_alerts
      else
        ENV.delete("ALERTS_ENABLED")
      end
    end

    test "show confirm page for unsubscribe all" do
      get subscriptions_unsubscribe_path(token: @raw, scope: "all")
      assert_response :success
      assert_includes response.body, "Unsubscribe from all"
    end

    test "create unsubscribes all" do
      post subscriptions_unsubscribe_path(token: @raw), params: { scope: "all" }
      assert_redirected_to subscriptions_path
      assert @subscriber.reload.unsubscribed?
    end

    test "create unsubscribes single watch" do
      post subscriptions_unsubscribe_path(token: @raw), params: {
        scope: "watch",
        watch_id: @watch.id
      }
      assert_redirected_to subscriptions_path
      assert_not StationWatch.exists?(@watch.id)
      assert_not @subscriber.reload.unsubscribed?
    end
  end
end
