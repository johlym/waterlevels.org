# frozen_string_literal: true

require "test_helper"

class Alerts::FloodEvaluatorTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location)
    @subscriber = create(:subscriber, :verified)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
    @rule = create(
      :alert_rule,
      station_watch: @watch,
      kind: "flood_category_change",
      params: { "notify_clear" => true, "min_severity" => "minor" }
    )
  end

  test "matches escalate to min severity or above" do
    event = build_event(from: "no_flooding", to: "minor")
    assert Alerts::FloodEvaluator.matches?(rule: @rule, event: event)
  end

  test "ignores escalate below min severity" do
    event = build_event(from: "no_flooding", to: "action")
    assert_not Alerts::FloodEvaluator.matches?(rule: @rule, event: event)
  end

  test "matches clear when notify_clear and from meets min severity" do
    event = build_event(from: "moderate", to: "no_flooding")
    assert Alerts::FloodEvaluator.matches?(rule: @rule, event: event)
  end

  test "skips clear when notify_clear false" do
    @rule.update!(params: @rule.params.merge("notify_clear" => false))
    event = build_event(from: "major", to: "no_flooding")
    assert_not Alerts::FloodEvaluator.matches?(rule: @rule, event: event)
  end

  test "skips clear when from was below min severity" do
    event = build_event(from: "action", to: "no_flooding")
    assert_not Alerts::FloodEvaluator.matches?(rule: @rule, event: event)
  end

  private

  def build_event(from:, to:)
    create(
      :alert_event,
      monitoring_location: @location,
      kind: "flood_category_change",
      payload: { "from" => from, "to" => to, "observed_at" => Time.current.iso8601 }
    )
  end
end
