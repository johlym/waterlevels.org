require "test_helper"

module DailyArchive
  class UsgsLikeDailyMeanTest < ActiveSupport::TestCase
    setup do
      @location = create(:monitoring_location, time_zone: "PST", state_code: "wa")
      @series = create(:time_series, monitoring_location: @location)
    end

    test "means continuous points in station-local midnight window" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      day = Date.new(2026, 1, 15)
      noon = zone.local(2026, 1, 15, 12, 0, 0)
      now = Time.current
      rows = [
        { observed_at: zone.local(2026, 1, 15, 0, 0, 0), value: 10.0 },
        { observed_at: noon, value: 20.0 },
        # Outside local day (previous evening local)
        { observed_at: zone.local(2026, 1, 14, 23, 0, 0), value: 999.0 }
      ]
      # Force coverage gate by adding filler points at 15-min cadence.
      # Noon is already present, so skip that slot.
      t = zone.local(2026, 1, 15, 0, 15, 0)
      while t < zone.local(2026, 1, 16, 0, 0, 0)
        rows << { observed_at: t, value: 15.0 } unless t == noon
        t += 15.minutes
      end
      ContinuousObservation.insert_all(rows.map { |row|
        {
          time_series_id: @series.id,
          observed_at: row[:observed_at],
          value: row[:value],
          created_at: now,
          updated_at: now
        }
      })

      point = UsgsLikeDailyMean.new(time_series: @series, day: day).compute
      assert_not_nil point
      assert_equal "2026-01-15", point["d"]
      assert_equal "derived", point["s"]
      assert_in_delta 15.0, point["v"], 5.0
    end

    test "returns nil when coverage is too thin" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: zone.local(2026, 2, 1, 12, 0, 0),
        value: 5.0
      )

      assert_nil UsgsLikeDailyMean.new(time_series: @series, day: Date.new(2026, 2, 1)).compute
    end

    test "rollup_day_for is 30 local days before today" do
      travel_to Time.utc(2026, 8, 7, 18, 0, 0) do
        day = UsgsLikeDailyMean.rollup_day_for(@location)
        # PST/PDT: 2026-08-07 local is still Aug 7
        assert_equal Date.new(2026, 7, 8), day
      end
    end
  end
end
