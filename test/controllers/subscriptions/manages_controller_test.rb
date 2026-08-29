# frozen_string_literal: true

require "test_helper"

module Subscriptions
  class ManagesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @previous_alerts = ENV["ALERTS_ENABLED"]
      ENV["ALERTS_ENABLED"] = "1"
      @subscriber = create(:subscriber, :verified)
      @raw = @subscriber.manage_token!
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

    test "show preference center" do
      get subscriptions_manage_path(token: @raw)
      assert_response :success
      assert_includes response.body, @subscriber.email
      assert_includes response.body, @location.display_name
      assert_includes response.body, "Flood category changes"
      assert_includes response.body, "state-intro"
      assert_includes response.body, "btn-secondary"
      # Nested forms break Save preferences — Remove must not use button_to inside the form.
      assert_select "form form", count: 0
      assert_includes response.body, "Remove station"
      assert_match(/data-turbo-method=["']delete["']/, response.body)
    end

    test "update preferences and rules" do
      patch subscriptions_manage_path(token: @raw), params: {
        subscriber: {
          time_zone: "America/Chicago",
          digest_hour: 8,
          digest_minute: 30,
          digest_enabled: "1"
        },
        watches: {
          @watch.id.to_s => {
            flood_enabled: "1",
            digest_enabled: "0",
            threshold_enabled: "1",
            threshold_parameter: "discharge",
            threshold_op: "above",
            threshold_value: "1200"
          }
        }
      }

      assert_redirected_to subscriptions_manage_path(token: @raw)
      @subscriber.reload
      assert_equal "America/Chicago", @subscriber.time_zone
      assert_equal 8, @subscriber.digest_hour
      assert_equal 30, @subscriber.digest_minute

      digest_rule = @watch.rule_for("digest")
      assert_not digest_rule.enabled?

      threshold = @watch.rule_for("threshold")
      assert threshold.enabled?
      assert_equal "discharge", threshold.param("parameter")
      assert_equal "1200", threshold.param("value").to_s
    end

    test "destroy watch" do
      assert_difference -> { @subscriber.station_watches.count }, -1 do
        delete subscriptions_manage_watch_path(token: @raw, id: @watch.id)
      end
      assert_redirected_to subscriptions_manage_path(token: @raw)
    end

    test "pause and unpause" do
      post subscriptions_manage_pause_path(token: @raw)
      assert @subscriber.reload.paused?

      post subscriptions_manage_unpause_path(token: @raw)
      assert_not @subscriber.reload.paused?
    end
  end
end
