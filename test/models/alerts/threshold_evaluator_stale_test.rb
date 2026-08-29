# frozen_string_literal: true

require "test_helper"

class Alerts::ThresholdEvaluatorStaleTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location,
                       latest_water_level_value: 20.0,
                       latest_observed_at: 8.hours.ago)
    @series = create(:time_series, monitoring_location: @location, measurement_kind: "water_level")
    LatestObservation.create!(
      time_series: @series,
      observed_at: 8.hours.ago,
      value: 20.0,
      unit_of_measure: "ft",
      synced_at: Time.current
    )
    @subscriber = create(:subscriber, :verified)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    @rule = create(
      :alert_rule,
      station_watch: @watch,
      kind: "threshold",
      params: {
        "parameter" => "water_level",
        "op" => "above",
        "value" => 10,
        "duration_minutes" => 0,
        "cooldown_minutes" => 0
      },
      armed: true
    )
  end

  test "does not fire when tip is older than STALE_TIP_AFTER" do
    refute Alerts::ThresholdEvaluator.new(rule: @rule, location: @location).should_fire?
  end

  test "fires when tip is fresh" do
    @location.update!(latest_observed_at: Time.current)
    @series.latest_observation.update!(observed_at: Time.current)
    assert Alerts::ThresholdEvaluator.new(rule: @rule, location: @location.reload).should_fire?
  end
end
