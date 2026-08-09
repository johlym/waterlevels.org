require "test_helper"

class DailyArchiveTest < ActiveSupport::TestCase
  test "time_series_ids_with_daily_on_or_before unions hot rows and shard min_on" do
    hot_series = create(:time_series)
    cold_series = create(:time_series)
    missing_series = create(:time_series)
    anchor = 35.months.ago.to_date

    DailyObservation.create!(time_series: hot_series, observed_on: anchor, value: 1.0)
    DailyArchiveShard.create!(
      time_series: cold_series,
      year: anchor.year,
      object_key: "daily/v1/#{cold_series.id}/#{anchor.year}.json.gz",
      content_sha256: "x",
      point_count: 3,
      min_on: anchor,
      max_on: anchor + 10,
      source_mix: "usgs",
      synced_at: Time.current
    )
    DailyObservation.create!(time_series: missing_series, observed_on: Date.current, value: 1.0)

    ids = DailyArchive.time_series_ids_with_daily_on_or_before(anchor).pluck(:id)
    assert_includes ids, hot_series.id
    assert_includes ids, cold_series.id
    refute_includes ids, missing_series.id
  end

  test "cold_archive_point_count sums shards entirely before the hot cutoff" do
    travel_to Time.zone.local(2026, 8, 6, 12, 0, 0) do
      series = create(:time_series)
      cutoff = DailyArchive.hot_cutoff_on
      # Fully cold prior calendar year vs straddling tip-year shard.
      cold_year = cutoff.year - 1
      tip_year = cutoff.year

      DailyArchiveShard.create!(
        time_series: series,
        year: cold_year,
        object_key: "daily/v1/#{series.id}/#{cold_year}.json.gz",
        content_sha256: "cold",
        point_count: 7,
        min_on: Date.new(cold_year, 1, 1),
        max_on: Date.new(cold_year, 12, 31),
        source_mix: "usgs",
        synced_at: Time.current
      )
      DailyArchiveShard.create!(
        time_series: series,
        year: tip_year,
        object_key: "daily/v1/#{series.id}/#{tip_year}.json.gz",
        content_sha256: "hot",
        point_count: 9,
        min_on: Date.new(tip_year, 1, 1),
        max_on: Date.new(tip_year, 12, 31),
        source_mix: "usgs",
        synced_at: Time.current
      )

      assert_equal 7, DailyArchive.cold_archive_point_count
    end
  end
end
