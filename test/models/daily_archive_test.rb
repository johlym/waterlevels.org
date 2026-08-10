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

    ids = DailyArchive.time_series_ids_with_daily_on_or_before(anchor).pluck(:time_series_id)
    assert_includes ids, hot_series.id
    assert_includes ids, cold_series.id
    refute_includes ids, missing_series.id
  end

  test "archive_point_count sums all shard point_counts" do
    series = create(:time_series)
    DailyArchiveShard.create!(
      time_series: series,
      year: 2024,
      object_key: "daily/v1/#{series.id}/2024.json.gz",
      content_sha256: "a",
      point_count: 7,
      min_on: Date.new(2024, 1, 1),
      max_on: Date.new(2024, 12, 31),
      source_mix: "usgs",
      synced_at: Time.current
    )
    DailyArchiveShard.create!(
      time_series: series,
      year: 2025,
      object_key: "daily/v1/#{series.id}/2025.json.gz",
      content_sha256: "b",
      point_count: 9,
      min_on: Date.new(2025, 1, 1),
      max_on: Date.new(2025, 6, 1),
      source_mix: "usgs",
      synced_at: Time.current
    )

    assert_equal 16, DailyArchive.archive_point_count
    assert_equal 16, DailyArchive.cold_archive_point_count
  end

  test "time_series_ids_with_fresh_daily_tip uses shard max_on" do
    series = create(:time_series)
    DailyArchiveShard.create!(
      time_series: series,
      year: Date.current.year,
      object_key: "daily/v1/#{series.id}/#{Date.current.year}.json.gz",
      content_sha256: "c",
      point_count: 2,
      min_on: 10.days.ago.to_date,
      max_on: Date.current,
      source_mix: "usgs",
      synced_at: Time.current
    )

    ids = DailyArchive.time_series_ids_with_fresh_daily_tip(2.days.ago.to_date).pluck(:time_series_id)
    assert_includes ids, series.id
  end

  test "fresh_daily_tip_series_ids unions hot rows and shard max_on" do
    hot_series = create(:time_series)
    cold_series = create(:time_series)
    stale_series = create(:time_series)
    since_on = 2.days.ago.to_date

    DailyObservation.create!(time_series: hot_series, observed_on: Date.current, value: 1.0)
    DailyArchiveShard.create!(
      time_series: cold_series,
      year: Date.current.year,
      object_key: "daily/v1/#{cold_series.id}/#{Date.current.year}.json.gz",
      content_sha256: "tip",
      point_count: 2,
      min_on: 10.days.ago.to_date,
      max_on: Date.current,
      source_mix: "usgs",
      synced_at: Time.current
    )
    DailyObservation.create!(time_series: stale_series, observed_on: 10.days.ago.to_date, value: 1.0)

    ids = DailyArchive.fresh_daily_tip_series_ids(since_on)
    assert_includes ids, hot_series.id
    assert_includes ids, cold_series.id
    refute_includes ids, stale_series.id
  end
end
