require "test_helper"

class GaugeFloodStageTest < ActiveSupport::TestCase
  # Mendenhall River near Auke Bay, 2026-10-01: observed 6 ft and no flooding,
  # forecast 10 ft / moderate. Thresholds from NWPS.
  MENDENHALL_STAGES = { action: 8, minor: 9, moderate: 10, major: 14 }.freeze

  test "names the current flood tier from gage height, not a higher forecast category" do
    stage = GaugeFloodStage.new(
      stages: { action: 5, minor: 10, moderate: 12, major: 14 },
      stage_ft: 11
    )

    assert_equal "minor", stage.category
    assert_equal "Minor Flooding", stage.headline
    assert_equal "minor at 10 ft", stage.detail
    assert_equal "Minor Flooding", stage.pill_label
  end

  test "reports below flood stage and the lowest flood level when height is under every tier" do
    stage = GaugeFloodStage.new(stages: MENDENHALL_STAGES, stage_ft: 6)

    assert_equal "below", stage.category
    assert_equal "Not at flood stage", stage.headline
    assert_equal "Lowest flood stage is minor at 9 ft", stage.detail
    assert_equal "Not at flood stage. Lowest flood stage is minor at 9 ft", stage.text
    assert_not_includes stage.text, "Moderate"
  end

  test "keeps action stage and still names the lowest flood level" do
    stage = GaugeFloodStage.new(stages: MENDENHALL_STAGES, stage_ft: 8.2)

    assert_equal "action", stage.category
    assert_equal "Action stage", stage.headline
    assert_equal "Lowest flood stage is minor at 9 ft", stage.detail
  end

  test "uses the lowest published flood tier when minor is missing" do
    stage = GaugeFloodStage.new(
      stages: { action: 4, moderate: 12, major: 16 },
      stage_ft: 3
    )

    assert_equal "Not at flood stage", stage.headline
    assert_equal "Lowest flood stage is moderate at 12 ft", stage.detail
  end

  test "names the active tier level when the river is in major flooding" do
    stage = GaugeFloodStage.new(stages: MENDENHALL_STAGES, stage_ft: 14)

    assert_equal "major", stage.category
    assert_equal "Major Flooding", stage.headline
    assert_equal "major at 14 ft", stage.detail
  end

  test "treats the threshold as inclusive" do
    stage = GaugeFloodStage.new(stages: MENDENHALL_STAGES, stage_ft: 9)

    assert_equal "minor", stage.category
    assert_equal "Minor Flooding", stage.headline
  end

  test "names the lowest flood level when stage thresholds exist but gage height does not" do
    stage = GaugeFloodStage.new(stages: MENDENHALL_STAGES, measurements: [])

    assert_nil stage.category
    assert_nil stage.pill_label
    assert_equal "Lowest flood stage is minor at 9 ft", stage.headline
    assert_nil stage.detail
  end

  test "ignores a stored forecast category when there is no gage height to classify" do
    stage = GaugeFloodStage.from_snapshot(
      flood_category: "moderate",
      flood_category_label: "Moderate Flooding",
      flood_stages: MENDENHALL_STAGES,
      measurements: []
    )

    assert_equal "Lowest flood stage is minor at 9 ft", stage.text
    assert_not_includes stage.text, "Moderate"
  end

  test "reads usgs gage height in feet from the snapshot" do
    stage = GaugeFloodStage.from_snapshot(
      flood_stages: MENDENHALL_STAGES,
      measurements: [
        { parameter_code: "62615", kind: "water_level", value: 500.0, unit: "ft" },
        { parameter_code: "00065", kind: "water_level", value: 6.0, unit: "ft" }
      ]
    )

    assert_equal "Not at flood stage", stage.headline
    assert_equal "Lowest flood stage is minor at 9 ft", stage.detail
  end

  test "reads nwps stage and ignores non-feet units" do
    meters = GaugeFloodStage.from_snapshot(
      flood_stages: MENDENHALL_STAGES,
      measurements: [ { parameter_code: "00065", value: 6.0, unit: "m" } ]
    )
    nwps = GaugeFloodStage.from_snapshot(
      flood_stages: { "minor" => 9.5 },
      measurements: [ { "parameter_code" => "NWPS:Stage", "value" => 9.5, "unit" => "ft" } ]
    )

    assert_equal "Lowest flood stage is minor at 9 ft", meters.headline
    assert_nil meters.detail
    assert_equal "Minor Flooding", nwps.headline
    assert_equal "minor at 9.50 ft", nwps.detail
  end

  test "says there is no flood stage data when thresholds are missing" do
    stage = GaugeFloodStage.from_snapshot(
      flood_category: "moderate",
      flood_stages: { action: nil, minor: nil, moderate: nil, major: nil },
      measurements: [ { parameter_code: "00065", value: 12.0, unit: "ft" } ]
    )

    assert_equal "No flood stage data", stage.headline
    assert_nil stage.detail
    assert_nil stage.pill_label
  end

  test "action-only thresholds name that level when the river is below it" do
    stage = GaugeFloodStage.new(stages: { action: 5 }, stage_ft: 2)

    assert_equal "Not at flood stage", stage.headline
    assert_equal "Lowest flood stage is action at 5 ft", stage.detail
  end
end
