# frozen_string_literal: true

require "test_helper"

class Alerts::InRangeEvaluatorTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location, latest_discharge_value: 1200)
    @series = create(
      :time_series,
      monitoring_location: @location,
      measurement_kind: "discharge",
      parameter_code: "00060",
      unit_of_measure: "ft3/s"
    )
    LatestObservation.create!(
      time_series: @series,
      observed_at: Time.current,
      value: 1200,
      unit_of_measure: "ft3/s",
      synced_at: Time.current
    )
    @watch = create(:station_watch, subscriber: create(:subscriber), monitoring_location: @location)
    @rule = create(
      :alert_rule,
      station_watch: @watch,
      kind: "in_range",
      params: {
        "parameter" => "discharge",
        "min" => 800,
        "max" => 2000,
        "on" => "enter"
      }
    )
  end

  test "fires on enter when previous was outside and current inside" do
    assert Alerts::InRangeEvaluator.new(
      rule: @rule,
      location: @location,
      previous_value: 500
    ).should_fire?
  end

  test "does not fire on enter when already inside" do
    assert_not Alerts::InRangeEvaluator.new(
      rule: @rule,
      location: @location,
      previous_value: 900
    ).should_fire?
  end

  test "fires on leave when exiting corridor" do
    @rule.update!(params: @rule.params.merge("on" => "leave"))
    @location.update!(latest_discharge_value: 300)
    @series.latest_observation.update!(value: 300)
    assert Alerts::InRangeEvaluator.new(
      rule: @rule.reload,
      location: @location.reload,
      previous_value: 1200
    ).should_fire?
  end
end
