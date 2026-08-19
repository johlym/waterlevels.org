require "test_helper"

class ContinuousInventoryTest < ActiveSupport::TestCase
  test "15-minute coverage lands in the IV envelope and sampled spacing" do
    travel_to Time.utc(2026, 8, 19, 16, 0, 0) do
      location = create(:monitoring_location, state_code: "wa", latest_observed_at: Time.current)
      series = create(
        :time_series,
        monitoring_location: location,
        parameter_code: "00065",
        measurement_kind: "water_level",
        selected_for_display: true
      )
      leftover = create(
        :time_series,
        monitoring_location: location,
        parameter_code: "62615",
        measurement_kind: "water_level",
        selected_for_display: false,
        usgs_time_series_id: "ts-unselected-iv"
      )

      seed_continuous_coverage!(
        series,
        from: 35.days.ago,
        to: Time.current,
        step: 15.minutes
      )
      seed_continuous_coverage!(
        leftover,
        from: 2.hours.ago,
        to: Time.current,
        step: 15.minutes
      )
      leftover.update!(selected_for_display: false)
      ContinuousObservation.create!(
        time_series: series,
        value: 1,
        observed_at: 36.days.ago
      )

      snap = ContinuousInventory.snapshot(exact: true, sample: 10)
      report = ContinuousInventory.report(exact: true, sample: 10)

      assert_equal 35, snap[:retention_days]
      assert_equal 1, snap[:station_count]
      assert_equal 1, snap[:selected_series_count]
      assert_equal 1, snap[:selected_series_with_continuous_count]
      assert_equal 1, snap[:unselected_series_with_continuous_count]
      assert_equal 1, snap[:beyond_retention_count]
      assert_in_delta 1.0, snap[:ratio_to_15min_full], 0.05
      assert_in_delta 15.minutes, snap[:sampled_cadence][:median_interval_seconds], 30
      assert_includes snap[:verdicts].join(" "), "15-minute IV envelope"
      assert_includes snap[:verdicts].join(" "), "sampled series median spacing"
      assert_includes snap[:verdicts].join(" "), "unselected series"
      assert_includes snap[:verdicts].join(" "), "older than retention"
      assert_includes report, "hourly × stations × 1 series"
      assert_includes report, "puts ContinuousInventory.report"
    end
  end

  test "hourly mental math is about 4x below a full 15-minute series" do
    travel_to Time.utc(2026, 8, 19, 16, 0, 0) do
      location = create(:monitoring_location, state_code: "or", latest_observed_at: Time.current)
      series = create(:time_series, monitoring_location: location, selected_for_display: true)
      seed_continuous_coverage!(series, from: 1.hour.ago, to: Time.current, step: 15.minutes)

      snap = ContinuousInventory.snapshot(exact: true, sample: 5)

      assert_equal 1 * 24 * 35, snap[:expected_hourly_one_series]
      assert_equal 1 * 96 * 35, snap[:expected_15min_full]
      assert_equal snap[:expected_hourly_one_series] * 4, snap[:expected_15min_full]
    end
  end
end
