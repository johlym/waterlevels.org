# frozen_string_literal: true

require "test_helper"

class Alerts::PriorLookupTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location)
    @series = create(:time_series, monitoring_location: @location)
    @now = Time.zone.parse("2026-08-29T20:00:00Z")
    ContinuousObservation.create!(time_series: @series, observed_at: 6.hours.before(@now), value: 8.0)
    ContinuousObservation.create!(time_series: @series, observed_at: 2.hours.before(@now), value: 9.5)
    ContinuousObservation.create!(time_series: @series, observed_at: @now, value: 10.0)
  end

  test "returns most recent continuous value at or before cutoff" do
    prior = Alerts::PriorLookup.value_for(@series, hours: 3, at: @now)
    # cutoff = now - 3h; points at 6h-ago and 2h-ago → only 6h-ago qualifies
    assert_in_delta 8.0, prior.to_f, 0.001
  end

  test "prefers nearer prior inside a longer window" do
    prior = Alerts::PriorLookup.value_for(@series, hours: 1, at: @now)
    # cutoff = now - 1h; both 6h-ago and 2h-ago qualify → pick nearer (2h)
    assert_in_delta 9.5, prior.to_f, 0.001
  end

  test "returns nil when no prior exists" do
    prior = Alerts::PriorLookup.value_for(@series, hours: 24, at: 1.day.before(@now))
    assert_nil prior
  end

  test "builds trend comparison with configurable hours label" do
    comparison = Alerts::PriorLookup.for_series(
      @series,
      hours: 2,
      current_value: 10.0,
      at: @now
    )
    assert_equal "2.0h", comparison.label
    assert_in_delta 0.5, comparison.delta, 0.001
  end
end
