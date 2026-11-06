# frozen_string_literal: true

require "test_helper"

class AlertRuleTest < ActiveSupport::TestCase
  setup do
    @watch = create(:station_watch)
  end

  test "flood rules have no implicit cooldown" do
    rule = @watch.rule_for("flood_category_change")
    assert_equal 0, rule.cooldown_minutes
    assert_not rule.in_cooldown?
  end

  test "threshold rules default to a 6 hour cooldown" do
    rule = create(:alert_rule, :threshold, station_watch: @watch, params: {
      "parameter" => "water_level",
      "op" => "above",
      "value" => 10.0
    })
    assert_equal 360, rule.cooldown_minutes
  end

  test "explicit cooldown_minutes wins for flood rules" do
    rule = @watch.rule_for("flood_category_change")
    rule.update!(params: rule.params.merge("cooldown_minutes" => 90))
    assert_equal 90, rule.cooldown_minutes
  end

  test "firing a flood rule does not start a cooldown" do
    rule = @watch.rule_for("flood_category_change")
    rule.mark_fired!
    assert_not rule.in_cooldown?
  end
end
