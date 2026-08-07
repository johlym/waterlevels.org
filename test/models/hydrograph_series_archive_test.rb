require "test_helper"

class HydrographSeriesArchiveTest < ActiveSupport::TestCase
  setup do
    @store = DailyArchive::MemoryStore.new
    DailyArchive.store = @store
    ENV["DAILY_ARCHIVE_READS"] = "1"
    @location = create(:monitoring_location)
    @series = create(
      :time_series,
      monitoring_location: @location,
      measurement_kind: "water_level",
      parameter_code: "00065",
      selected_for_display: true
    )
  end

  teardown do
    DailyArchive.reset_store!
    ENV.delete("DAILY_ARCHIVE_READS")
  end

  test "3y merges cold archive points with postgres hot tip" do
    hot_day = 2.months.ago.to_date
    cold_day = 20.months.ago.to_date
    DailyObservation.create!(time_series: @series, observed_on: hot_day, value: 5.0)
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => cold_day.iso8601, "v" => 1.5, "s" => "usgs" } ]
    )

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "3y")
    days = payload[:points].map { |p| p[:t] }
    assert_includes days, cold_day.iso8601
    assert_includes days, hot_day.iso8601
  end

  test "1y does not read from archive" do
    cold_day = 20.months.ago.to_date
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => cold_day.iso8601, "v" => 1.5, "s" => "usgs" } ]
    )

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "1y")
    days = payload[:points].map { |p| p[:t] }
    refute_includes days, cold_day.iso8601
  end
end
