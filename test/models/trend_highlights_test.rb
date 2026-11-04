require "test_helper"

class TrendHighlightsTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "ranks stage rises by feet inside the 18 to 30 hour window" do
    observed_at = tip_at
    big, _series = build_series(
      name: "Big Rise Creek",
      current: 10,
      observed_at: observed_at,
      priors: [ { value: 4, at: observed_at - 24.hours } ]
    )
    small, _series = build_series(
      name: "Small Rise Creek",
      current: 5.5,
      observed_at: observed_at,
      priors: [ { value: 5, at: observed_at - 24.hours } ]
    )
    outside, _series = build_series(
      name: "Outside Window Creek",
      current: 30,
      observed_at: observed_at,
      priors: [
        { value: 1, at: observed_at - 17.hours },
        { value: 1, at: observed_at - 31.hours }
      ]
    )

    payload = TrendHighlights.fetch
    numbers = payload[:stage_movers].map { |row| row[:site_number] }

    assert_equal [ big.site_number, small.site_number ], numbers
    assert_not_includes numbers, outside.site_number
    assert_in_delta 6.0, payload[:stage_movers].first[:delta], 0.001
    assert_includes payload[:stage_movers].first[:path], "/gauges/wa/#{big.site_number}-"
    assert_equal "Gage height", payload[:stage_movers].first[:label]
  end

  test "uses the continuous point closest to 24 hours ago and keeps window edges" do
    observed_at = tip_at
    closest, _series = build_series(
      name: "Closest Prior Creek",
      current: 10,
      observed_at: observed_at,
      priors: [
        { value: 1, at: observed_at - 23.hours },
        { value: 5, at: observed_at - 20.hours }
      ]
    )
    edge, _series = build_series(
      name: "Edge Prior Creek",
      current: 10,
      observed_at: observed_at,
      priors: [
        { value: 8, at: observed_at - 30.hours },
        { value: 3, at: observed_at - 18.hours }
      ]
    )

    payload = TrendHighlights.fetch
    by_site = payload[:stage_movers].index_by { |row| row[:site_number] }

    assert_in_delta 9.0, by_site[closest.site_number][:delta], 0.001
    # 18h and 30h are equally far from 24h; the newer point wins.
    assert_in_delta 7.0, by_site[edge.site_number][:delta], 0.001
  end

  test "keeps the eight largest stage rises" do
    observed_at = tip_at
    locations = (1..9).map do |n|
      location, _series = build_series(
        name: "Rank #{n} Creek",
        current: 2 + n,
        observed_at: observed_at,
        priors: [ { value: 2, at: observed_at - 24.hours } ]
      )
      location
    end

    numbers = TrendHighlights.fetch[:stage_movers].map { |row| row[:site_number] }

    assert_equal 8, numbers.size
    assert_equal locations[8].site_number, numbers.first
    assert_equal locations[1].site_number, numbers.last
    assert_not_includes numbers, locations[0].site_number
  end

  test "ranks discharge by percent above a 10 cfs prior" do
    observed_at = tip_at
    doubled, _series = build_series(
      name: "Doubled Flow Creek",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 20,
      observed_at: observed_at,
      priors: [ { value: 10, at: observed_at - 24.hours } ]
    )
    below_floor, _series = build_series(
      name: "Trickle Creek",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 90,
      observed_at: observed_at,
      priors: [ { value: 9, at: observed_at - 24.hours } ]
    )
    river, _series = build_series(
      name: "Big River",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 1100,
      observed_at: observed_at,
      priors: [ { value: 1000, at: observed_at - 24.hours } ]
    )

    rows = TrendHighlights.fetch[:discharge_movers]
    numbers = rows.map { |row| row[:site_number] }

    assert_equal [ doubled.site_number, river.site_number ], numbers
    assert_not_includes numbers, below_floor.site_number
    assert_in_delta 100.0, rows.first[:percent], 0.001
    assert_in_delta 10.0, rows.second[:percent], 0.001
    assert_equal "Flow", rows.first[:label]
  end

  test "keeps the primary discharge series when a station has more than one" do
    observed_at = tip_at
    location, primary = build_series(
      name: "Split Flow Creek",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 20,
      observed_at: observed_at,
      primary: true,
      priors: [ { value: 10, at: observed_at - 24.hours } ]
    )
    other = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      unit_of_measure: "ft3/s",
      selected_for_display: true,
      primary_series: false,
      provider_series_id: "ts-discharge-extra-#{location.id}"
    )
    LatestObservation.create!(
      time_series: other,
      value: 100,
      unit_of_measure: "ft3/s",
      observed_at: observed_at,
      synced_at: Time.current
    )
    ContinuousObservation.create!(
      time_series: other,
      value: 10,
      observed_at: observed_at - 24.hours
    )

    rows = TrendHighlights.fetch[:discharge_movers].select { |row| row[:site_number] == location.site_number }

    assert_equal 1, rows.size
    assert_in_delta 100.0, rows.first[:percent], 0.001
    assert_equal primary.id, location.time_series.find_by!(primary_series: true).id
  end

  test "skips inactive, unselected, stale, falling, and temperature series" do
    observed_at = tip_at
    stale_at = Time.zone.at(Time.current.to_i) - 7.hours
    skipped = []
    skipped << build_series(
      name: "Inactive Creek",
      current: 20,
      observed_at: observed_at,
      active: false,
      priors: [ { value: 1, at: observed_at - 24.hours } ]
    ).first
    skipped << build_series(
      name: "Hidden Creek",
      current: 20,
      observed_at: observed_at,
      selected: false,
      priors: [ { value: 1, at: observed_at - 24.hours } ]
    ).first
    skipped << build_series(
      name: "Falling Creek",
      current: 1,
      observed_at: observed_at,
      priors: [ { value: 5, at: observed_at - 24.hours } ]
    ).first
    skipped << build_series(
      name: "Stale Tip Creek",
      current: 20,
      observed_at: stale_at,
      priors: [ { value: 1, at: stale_at - 24.hours } ]
    ).first
    skipped << build_series(
      name: "Warm Creek",
      kind: "temperature",
      parameter_code: "00010",
      unit: "deg C",
      current: 30,
      observed_at: observed_at,
      priors: [ { value: 1, at: observed_at - 24.hours } ]
    ).first

    listed = TrendHighlights.fetch.values_at(:stage_movers, :discharge_movers).flatten.map { |row| row[:site_number] }

    skipped.each do |location|
      assert_not_includes listed, location.site_number, location.name
    end
  end

  test "uses only the preferred water level series" do
    observed_at = tip_at
    location, _preferred = build_series(
      name: "Preferred Stage Creek",
      current: 5.2,
      observed_at: observed_at,
      parameter_code: "00065",
      denorm_code: "00065",
      priors: [ { value: 5.0, at: observed_at - 24.hours } ]
    )
    other = create(
      :time_series,
      monitoring_location: location,
      parameter_code: "00062",
      measurement_kind: "water_level",
      unit_of_measure: "ft",
      selected_for_display: true,
      primary_series: false,
      provider_series_id: "ts-stage-extra-#{location.id}"
    )
    LatestObservation.create!(
      time_series: other,
      value: 20,
      unit_of_measure: "ft",
      observed_at: observed_at,
      synced_at: Time.current
    )
    ContinuousObservation.create!(
      time_series: other,
      value: 1,
      observed_at: observed_at - 24.hours
    )

    rows = TrendHighlights.fetch[:stage_movers].select { |row| row[:site_number] == location.site_number }

    assert_equal 1, rows.size
    assert_in_delta 0.2, rows.first[:delta], 0.001
  end

  test "lists a new high only with ten water years strictly above the stored peaks" do
    observed_at = tip_at
    record_location, record_series = build_series(
      name: "Record Creek",
      current: 12,
      observed_at: observed_at
    )
    add_peaks(record_series, years: 2000..2009, value: 9)

    thin_location, thin_series = build_series(
      name: "Thin History Creek",
      current: 12,
      observed_at: observed_at
    )
    add_peaks(thin_series, years: 2000..2008, value: 9)

    equal_location, equal_series = build_series(
      name: "Equal Peak Creek",
      current: 9,
      observed_at: observed_at
    )
    add_peaks(equal_series, years: 1990..1999, value: 9)

    stale_location, stale_series = build_series(
      name: "Stale Record Creek",
      current: 12,
      observed_at: Time.zone.at(Time.current.to_i) - 8.days
    )
    add_peaks(stale_series, years: 1980..1989, value: 9)

    rows = TrendHighlights.fetch[:records]
    numbers = rows.map { |row| row[:site_number] }

    assert_equal [ record_location.site_number ], numbers
    assert_not_includes numbers, thin_location.site_number
    assert_not_includes numbers, equal_location.site_number
    assert_not_includes numbers, stale_location.site_number
    assert_in_delta 3.0, rows.first[:margin], 0.001
    assert_equal 2000, rows.first[:year_min]
    assert_equal 2009, rows.first[:year_max]
    assert_equal "Gage height", rows.first[:label]
  end

  test "ranks discharge records by percent above the stored peak" do
    observed_at = tip_at
    small, small_series = build_series(
      name: "Small Record River",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 110,
      observed_at: observed_at
    )
    add_peaks(small_series, years: 2000..2009, value: 100)

    large, large_series = build_series(
      name: "Large Record River",
      kind: "discharge",
      parameter_code: "00060",
      unit: "ft3/s",
      current: 50,
      observed_at: observed_at
    )
    add_peaks(large_series, years: 2000..2009, value: 10)

    numbers = TrendHighlights.fetch[:records].map { |row| row[:site_number] }

    assert_equal [ large.site_number, small.site_number ], numbers
  end

  test "mention_for reads the cache and does not compute" do
    sql = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      sql << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_nil TrendHighlights.mention_for("12101000")
    end
    assert_empty sql

    Rails.cache.write(
      TrendHighlights::CACHE_KEY,
      {
        stage_movers: [ { site_number: "111" } ],
        discharge_movers: [],
        records: [ { site_number: "111" }, { site_number: "222" } ]
      }
    )

    both = TrendHighlights.mention_for("111")
    assert_equal "home-trends", both[:anchor]
    assert_equal "Featured in today's rising stations and new highs", both[:text]

    record = TrendHighlights.mention_for("222")
    assert_equal "new-highs", record[:anchor]
    assert_equal "Featured in today's new highs", record[:text]

    assert_nil TrendHighlights.mention_for("333")
  end

  private

  def tip_at
    Time.zone.at(Time.current.to_i) - 1.hour
  end

  def build_series(
    name:,
    current:,
    priors: [],
    observed_at: nil,
    parameter_code: "00065",
    kind: "water_level",
    unit: "ft",
    active: true,
    selected: true,
    primary: true,
    denorm_code: "00065"
  )
    observed_at ||= tip_at
    location = create(
      :monitoring_location,
      name: name,
      active: active,
      latest_water_level_parameter_code: denorm_code,
      latest_observed_at: observed_at
    )
    series = create(
      :time_series,
      monitoring_location: location,
      parameter_code: parameter_code,
      measurement_kind: kind,
      unit_of_measure: unit,
      selected_for_display: selected,
      primary_series: primary
    )
    LatestObservation.create!(
      time_series: series,
      value: current,
      unit_of_measure: unit,
      observed_at: observed_at,
      synced_at: Time.current
    )
    priors.each do |prior|
      ContinuousObservation.create!(
        time_series: series,
        value: prior[:value],
        observed_at: prior[:at]
      )
    end
    [ location, series ]
  end

  def add_peaks(series, years:, value:)
    years.each do |year|
      PeakObservation.create!(
        time_series: series,
        water_year: year,
        value: value,
        peak_kind: "high",
        observed_at: Time.zone.local(year, 6, 1)
      )
    end
  end
end
