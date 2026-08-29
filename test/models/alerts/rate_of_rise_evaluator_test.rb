# frozen_string_literal: true

require "test_helper"

class Alerts::RateOfRiseEvaluatorTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location)
    @series = create(:time_series, monitoring_location: @location, measurement_kind: "water_level")
    @now = Time.zone.parse("2026-08-29T18:00:00Z")
    LatestObservation.create!(
      time_series: @series,
      observed_at: @now,
      value: 12.0,
      unit_of_measure: "ft",
      synced_at: @now
    )
    ContinuousObservation.create!(time_series: @series, observed_at: 3.hours.before(@now), value: 10.0)
    ContinuousObservation.create!(time_series: @series, observed_at: @now, value: 12.0)

    @watch = create(:station_watch, subscriber: create(:subscriber), monitoring_location: @location)
    @rule = create(
      :alert_rule,
      station_watch: @watch,
      kind: "rate_of_rise",
      params: {
        "parameter" => "water_level",
        "window_hours" => 3,
        "delta" => 1.5,
        "cooldown_minutes" => 360
      }
    )
  end

  test "fires when rise meets delta over window" do
    assert Alerts::RateOfRiseEvaluator.new(rule: @rule, location: @location, at: @now).should_fire?
  end

  test "does not fire when rise is below delta" do
    @rule.update!(params: @rule.params.merge("delta" => 3.0))
    assert_not Alerts::RateOfRiseEvaluator.new(rule: @rule.reload, location: @location, at: @now).should_fire?
  end
end
