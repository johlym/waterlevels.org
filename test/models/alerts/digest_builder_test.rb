# frozen_string_literal: true

require "test_helper"

class Alerts::DigestBuilderTest < ActiveSupport::TestCase
  setup do
    @location = create(
      :monitoring_location,
      latest_water_level_value: 11.2,
      latest_water_level_unit: "ft",
      latest_discharge_value: 450,
      latest_discharge_unit: "ft3/s",
      flood_category: "action",
      latest_observed_at: 30.minutes.ago
    )
    @series = create(:time_series, monitoring_location: @location, measurement_kind: "water_level")
    ContinuousObservation.create!(
      time_series: @series,
      observed_at: 24.hours.before(@location.latest_observed_at),
      value: 10.0
    )
    @subscriber = create(:subscriber, :verified)
    @watch = create(:station_watch, subscriber: @subscriber, monitoring_location: @location, label: "Home gauge")
  end

  test "builds station snapshot with level discharge flood and stale" do
    snapshot = Alerts::DigestBuilder.new(@subscriber).build
    assert_equal @subscriber.id, snapshot[:subscriber_id]
    assert_equal 1, snapshot[:stations].size

    station = snapshot[:stations].first
    assert_equal @location.id, station[:monitoring_location_id]
    assert_equal "Home gauge", station[:label]
    assert_in_delta 11.2, station[:water_level].to_f, 0.001
    assert_in_delta 450, station[:discharge].to_f, 0.001
    assert_equal "action", station[:flood_category]
    assert_equal false, station[:stale]
    assert_in_delta 1.2, station[:delta_24h].to_f, 0.001
  end

  test "omits watches without enabled digest include" do
    @watch.rule_for("digest").update!(params: { "include" => false })
    snapshot = Alerts::DigestBuilder.new(@subscriber).build
    assert_empty snapshot[:stations]
  end
end
