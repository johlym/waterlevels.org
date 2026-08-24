require "test_helper"

class StationCatalogCheckpointTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    StationCatalogCheckpoint.clear_all!
    @sunday = Time.utc(2026, 8, 23, 12, 0, 0)
  end

  teardown do
    StationCatalogCheckpoint.clear_all!
    Rails.cache = @previous_cache
  end

  test "resume_or_start reuses matching week and scope" do
    first = StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
    first.mark_parameter!("00060", kept_location_ids: [ "USGS-12101000" ], discovered_rows: 4)
    refute first.resumed

    monday = StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday + 1.day)
    assert monday.resumed
    assert monday.completed?("00060")
    assert_equal [ "USGS-12101000" ], monday.kept_location_ids
    assert_equal 4, monday.discovered_rows
    assert_equal Usgs::ParameterCodes::ALL.map(&:to_s) - [ "00060" ], monday.remaining_parameter_codes
  end

  test "resume_or_start starts fresh on the next Sunday" do
    StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
      .mark_parameter!("00060", kept_location_ids: [ "USGS-1" ], discovered_rows: 1)

    fresh = StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday + 7.days)
    refute fresh.resumed
    assert_equal [], fresh.completed_parameter_codes
    assert_equal [], fresh.kept_location_ids
  end

  test "national and state checkpoints do not share a cursor" do
    StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
      .mark_parameter!("00060", kept_location_ids: [ "USGS-1" ], discovered_rows: 1)

    state = StationCatalogCheckpoint.resume_or_start!(state: "wa", as_of: @sunday)
    refute state.resumed
    assert_equal [], state.completed_parameter_codes

    national = StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
    assert national.resumed
    assert national.completed?("00060")
  end

  test "fingerprint change from parameter list starts fresh" do
    StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
      .mark_parameter!("00060", kept_location_ids: [ "USGS-1" ], discovered_rows: 1)

    fresh = StationCatalogCheckpoint.resume_or_start!(
      state: nil,
      as_of: @sunday,
      parameter_codes: %w[00060 00010]
    )
    refute fresh.resumed
    assert_equal [], fresh.completed_parameter_codes
  end

  test "mark_parameter accumulates kept ids and discovered rows" do
    checkpoint = StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
    checkpoint.mark_parameter!("00060", kept_location_ids: [ "USGS-1", "USGS-2" ], discovered_rows: 3)
    checkpoint.mark_parameter!("00010", kept_location_ids: [ "USGS-2", "USGS-3" ], discovered_rows: 2)

    assert_equal %w[00060 00010], checkpoint.completed_parameter_codes
    assert_equal %w[USGS-1 USGS-2 USGS-3], checkpoint.kept_location_ids
    assert_equal 5, checkpoint.discovered_rows
  end

  test "clear_all removes national and state keys" do
    StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday)
      .mark_parameter!("00060", kept_location_ids: [ "USGS-1" ], discovered_rows: 1)
    StationCatalogCheckpoint.resume_or_start!(state: "or", as_of: @sunday)
      .mark_parameter!("00010", kept_location_ids: [ "USGS-2" ], discovered_rows: 1)

    StationCatalogCheckpoint.clear_all!

    refute StationCatalogCheckpoint.resume_or_start!(state: nil, as_of: @sunday).resumed
    refute StationCatalogCheckpoint.resume_or_start!(state: "or", as_of: @sunday).resumed
  end
end
