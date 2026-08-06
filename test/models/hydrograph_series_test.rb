require "test_helper"

class HydrographSeriesTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location)
    @series = create(
      :time_series,
      monitoring_location: @location,
      measurement_kind: "water_level",
      parameter_code: "00065",
      selected_for_display: true
    )
  end

  test "1y range returns daily points within one year" do
    DailyObservation.create!(time_series: @series, observed_on: 13.months.ago.to_date, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: 6.months.ago.to_date, value: 2.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 3.0)

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "1y")
    days = payload[:points].map { |point| Date.parse(point[:t]) }

    assert_equal "1y", payload[:range]
    refute_includes days, 13.months.ago.to_date
    assert_includes days, 6.months.ago.to_date
    assert_includes days, Date.current
  end

  test "3y range returns daily points within three years" do
    DailyObservation.create!(time_series: @series, observed_on: 40.months.ago.to_date, value: 0.5)
    DailyObservation.create!(time_series: @series, observed_on: 30.months.ago.to_date, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 3.0)

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "3y")
    days = payload[:points].map { |point| Date.parse(point[:t]) }

    assert_equal "3y", payload[:range]
    refute_includes days, 40.months.ago.to_date
    assert_includes days, 30.months.ago.to_date
    assert_includes days, Date.current
  end
end
