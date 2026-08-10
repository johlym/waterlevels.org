require "test_helper"

class StationInspectorTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @location = create(
      :monitoring_location,
      site_number: "08405200",
      name: "PECOS RIVER BELOW DARK CANYON AT CARLSBAD, NM",
      state_code: "nm",
      has_water_level: true,
      has_discharge: true,
      has_temperature: true
    )
    @stage = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
    @flow = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      selected_for_display: true
    )
    @temp = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true
    )
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "find resolves site number and slug prefix" do
    assert_equal @location, StationInspector.find("08405200")
    assert_equal @location, StationInspector.find("08405200-pecos-river-below-dark-canyon-at-carlsbad-nm")
    assert_nil StationInspector.find("99999999")
    assert_nil StationInspector.find("")
  end

  test "report flags missing year history on the selected series that lacks daily" do
    seed_complete_series!(@stage)
    seed_complete_series!(@flow)
    # Temperature selected but no daily history — mirrors prod incomplete sites.

    report = StationInspector.report(@location)
    assert report[:backfill][:missing_year_history]
    assert report[:backfill][:needs_history_backfill]
    assert_includes report[:history_gates][:blocking_year_series], "temperature/00010"

    codes = report[:findings].map { |f| f[:code] }
    assert_includes codes, "year_history_callout"
    assert_includes codes, "partial_table_risk"
  end

  test "report notes unselected series that still have observations" do
    @temp.update!(selected_for_display: false)
    @location.update!(has_temperature: false)
    ContinuousObservation.create!(
      time_series: @temp,
      value: 12.5,
      observed_at: 2.hours.ago
    )

    report = StationInspector.report(@location)
    finding = report[:findings].find { |f| f[:code] == "unselected_with_history" }
    assert finding
    assert_match(/temperature\/00010/, finding[:summary])
  end

  test "report flags discontinued series still selected while siblings report" do
    LatestObservation.create!(
      time_series: @stage,
      value: 4.0,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    LatestObservation.create!(
      time_series: @flow,
      value: 100.0,
      unit_of_measure: "ft3/s",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    LatestObservation.create!(
      time_series: @temp,
      value: 18.0,
      unit_of_measure: "degC",
      observed_at: Time.utc(2026, 7, 20, 12, 0, 0),
      synced_at: Time.current
    )

    report = StationInspector.report(@location)
    finding = report[:findings].find { |f| f[:code] == "discontinued_still_selected" }
    assert finding
    assert_match(/temperature\/00010/, finding[:summary])
  end

  test "report surfaces backfill cooldown when station still needs fill" do
    HistoryBackfillLock.cooldown!(@location.id)
    report = StationInspector.report(@location)

    assert report[:backfill][:cooling_down]
    assert_includes report[:findings].map { |f| f[:code] }, "backfill_cooldown"
  end

  test "to_text includes site number and findings" do
    text = StationInspector.new(@location).to_text
    assert_match(/08405200/, text)
    assert_match(/Findings:/, text)
    assert_match(/temperature\/00010/, text)
  end

  private

  def seed_complete_series!(series)
    ContinuousObservation.create!(
      time_series: series,
      value: 1.0,
      observed_at: 1.hour.ago
    )
    ContinuousObservation.create!(
      time_series: series,
      value: 1.1,
      observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago - 1.day
    )
    DailyObservation.create!(
      time_series: series,
      value: 1.2,
      observed_on: Date.current
    )
    DailyObservation.create!(
      time_series: series,
      value: 1.0,
      observed_on: HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date - 1.day
    )
    DailyObservation.create!(
      time_series: series,
      value: 0.9,
      observed_on: HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date - 1.day
    )
  end
end
