# frozen_string_literal: true

require "test_helper"

class Alerts::ThresholdEvaluatorTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location, latest_water_level_value: 13.0)
    @series = create(:time_series, monitoring_location: @location, measurement_kind: "water_level")
    LatestObservation.create!(
      time_series: @series,
      observed_at: Time.current,
      value: 13.0,
      unit_of_measure: "ft",
      synced_at: Time.current
    )
    @subscriber = create(:subscriber)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    @rule = create(
      :alert_rule,
      station_watch: @watch,
      kind: "threshold",
      params: {
        "parameter" => "water_level",
        "op" => "above",
        "value" => 12.0,
        "duration_minutes" => 30,
        "cooldown_minutes" => 360,
        "hysteresis" => 0.2
      },
      armed: true
    )
  end

  test "fires when all points in duration are above threshold and armed" do
    seed_window(value: 12.5)
    assert Alerts::ThresholdEvaluator.new(rule: @rule, location: @location).should_fire?
  end

  test "does not fire when a point in the window is below threshold" do
    now = Time.current
    ContinuousObservation.create!(time_series: @series, observed_at: 25.minutes.before(now), value: 11.0)
    ContinuousObservation.create!(time_series: @series, observed_at: 10.minutes.before(now), value: 13.0)
    ContinuousObservation.create!(time_series: @series, observed_at: 5.minutes.before(now), value: 13.0)
    assert_not Alerts::ThresholdEvaluator.new(rule: @rule, location: @location, at: now).should_fire?
  end

  test "does not fire while disarmed until hysteresis clears" do
    seed_window(value: 12.5)
    @rule.update!(armed: false)
    assert_not Alerts::ThresholdEvaluator.new(rule: @rule, location: @location).should_fire?

    @location.update!(latest_water_level_value: 11.7)
    @series.latest_observation.update!(value: 11.7)
    seed_window(value: 11.7)
    evaluator = Alerts::ThresholdEvaluator.new(rule: @rule.reload, location: @location.reload)
    assert_not evaluator.should_fire?
    assert @rule.reload.armed?
  end

  test "respects cooldown" do
    seed_window(value: 12.5)
    @rule.update!(last_fired_at: 1.minute.ago)
    assert_not Alerts::ThresholdEvaluator.new(rule: @rule, location: @location).should_fire?
  end

  test "below op fires when continuously under threshold" do
    @rule.update!(params: @rule.params.merge("op" => "below", "value" => 5.0))
    @location.update!(latest_water_level_value: 4.0)
    @series.latest_observation.update!(value: 4.0)
    seed_window(value: 4.0)
    assert Alerts::ThresholdEvaluator.new(rule: @rule.reload, location: @location.reload).should_fire?
  end

  private

  def seed_window(value:)
    now = Time.current
    [ 30, 15, 5 ].each do |mins_ago|
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: mins_ago.minutes.before(now),
        value: value
      )
    end
  end
end
