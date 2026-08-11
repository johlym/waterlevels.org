require "test_helper"

class TimeSeriesContinuousCoverageTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location, usgs_monitoring_location_id: "USGS-12101000")
    @series = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "62614",
      measurement_kind: "water_level",
      usgs_time_series_id: "ts-coverage"
    )
  end

  test "refresh_continuous_coverage! sets newest prev anchor and max gap from observations" do
    travel_to Time.zone.parse("2026-08-11 12:00:00") do
      older = HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago - 1.day
      prev = 3.hours.ago
      newest = 30.minutes.ago

      ContinuousObservation.create!(time_series: @series, observed_at: older, value: 1)
      ContinuousObservation.create!(time_series: @series, observed_at: prev, value: 2)
      ContinuousObservation.create!(time_series: @series, observed_at: newest, value: 3)

      assert_equal 1, TimeSeries.refresh_continuous_coverage!([ @series.id ])
      @series.reload

      assert_in_delta newest.to_i, @series.continuous_newest_at.to_i, 1
      assert_in_delta prev.to_i, @series.continuous_prev_at.to_i, 1
      assert @series.has_continuous_anchor?
      assert_operator @series.continuous_max_gap_seconds, :>, HistoryIngestion::CONTINUOUS_GAP_THRESHOLD.to_i
    end
  end

  test "refresh_continuous_coverage! clears columns when series has no observations" do
    @series.update_columns(
      continuous_newest_at: 1.hour.ago,
      continuous_prev_at: 2.hours.ago,
      has_continuous_anchor: true,
      continuous_max_gap_seconds: 9_999
    )

    TimeSeries.refresh_continuous_coverage!([ @series.id ])
    @series.reload

    assert_nil @series.continuous_newest_at
    assert_nil @series.continuous_prev_at
    refute @series.has_continuous_anchor?
    assert_equal 0, @series.continuous_max_gap_seconds
  end

  test "advance_continuous_tips! shifts prev and raises max gap on tip jump" do
    travel_to Time.zone.parse("2026-08-11 12:00:00") do
      first = 5.hours.ago
      second = 30.minutes.ago
      @series.update_columns(
        continuous_newest_at: first,
        continuous_prev_at: nil,
        continuous_max_gap_seconds: 3_600
      )

      TimeSeries.advance_continuous_tips!(@series.id => second)
      @series.reload

      assert_in_delta second.to_i, @series.continuous_newest_at.to_i, 1
      assert_in_delta first.to_i, @series.continuous_prev_at.to_i, 1
      assert_operator @series.continuous_max_gap_seconds, :>=, 4.hours.to_i
    end
  end

  test "advance_continuous_tips! leaves timestamps alone for same tip time" do
    tip = 1.hour.ago
    prev = 3.hours.ago
    @series.update_columns(continuous_newest_at: tip, continuous_prev_at: prev)

    TimeSeries.advance_continuous_tips!(@series.id => tip)
    @series.reload

    assert_in_delta tip.to_i, @series.continuous_newest_at.to_i, 1
    assert_in_delta prev.to_i, @series.continuous_prev_at.to_i, 1
  end

  test "HistoryIngestion continuous flush refreshes coverage columns" do
    travel_to Time.zone.parse("2026-08-11 12:00:00") do
      tip_at = 30.minutes.ago.utc
      anchor_at = (HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago - 1.day).utc
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "1",
                properties: {
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
                  time: tip_at.iso8601,
                  value: 12.5
                }
              },
              {
                id: "2",
                properties: {
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
                  time: anchor_at.iso8601,
                  value: 9.0
                }
              }
            ],
            links: []
          }.to_json
        )
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: { features: [], links: [] }.to_json
        )

      HistoryIngestion.new(monitoring_location: @location, range: "7d").perform

      @series.reload
      assert_in_delta tip_at.to_i, @series.continuous_newest_at.to_i, 1
      assert_in_delta anchor_at.to_i, @series.continuous_prev_at.to_i, 1
      assert @series.has_continuous_anchor?
    end
  end

  test "seed_continuous_coverage! refreshes denorm columns" do
    travel_to Time.zone.parse("2026-08-11 12:00:00") do
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 1.hour.ago
      )
      @series.reload
      assert @series.continuous_newest_at.present?
      assert @series.has_continuous_anchor?
      assert @series.continuous_prev_at.present?
    end
  end
end
