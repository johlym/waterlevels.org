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

  test "3y reads archive points from R2" do
    archive_day = 20.months.ago.to_date
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => archive_day.iso8601, "v" => 1.5, "s" => "usgs" } ]
    )

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "3y")
    days = payload[:points].map { |p| p[:t] }
    assert_includes days, archive_day.iso8601
  end

  test "1y reads from archive when enabled" do
    archive_day = 6.months.ago.to_date
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => archive_day.iso8601, "v" => 1.5, "s" => "usgs" } ]
    )

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "1y")
    days = payload[:points].map { |p| p[:t] }
    assert_includes days, archive_day.iso8601
  end

  test "derived archive points expose s for UI tagging" do
    day = 40.days.ago.to_date
    DailyArchive::Writer.new(store: @store).upsert(
      time_series_id: @series.id,
      points: [ { "d" => day.iso8601, "v" => 2.25, "s" => "derived" } ]
    )

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "1y")
    point = payload[:points].find { |p| p[:t] == day.iso8601 }
    assert_equal "derived", point[:s]
  end

  test "1y ignores leftover postgres when archive reads are enabled" do
    pg_only_day = 3.months.ago.to_date
    DailyObservation.create!(time_series: @series, observed_on: pg_only_day, value: 9.0)

    payload = HydrographSeries.for(location: @location, kind: "water_level", range: "1y")
    days = payload[:points].map { |p| p[:t] }
    refute_includes days, pg_only_day.iso8601
  end
end
