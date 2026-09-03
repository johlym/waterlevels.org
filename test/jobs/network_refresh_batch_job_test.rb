require "test_helper"
require "stringio"

class NetworkRefreshBatchJobTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
      .to_return(status: 404, body: "", headers: { "Content-Type" => "application/json" })
  end

  teardown do
    Nldi::RateLimitCircuit.clear!
    Rails.cache = @previous_cache
  end

  test "refreshes a limited batch of unsynced stations" do
    first = create(:monitoring_location, site_number: "40000001", usgs_monitoring_location_id: "USGS-40000001")
    second = create(:monitoring_location, site_number: "40000002", usgs_monitoring_location_id: "USGS-40000002")
    first, second = [ first, second ].sort_by(&:id)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert_equal 1, NetworkRefreshBatchJob.perform_now(1)
    end

    assert first.reload.network_synced_at.present?
    assert_nil second.reload.network_synced_at
  end

  test "emits SyncProgress lines for the batch" do
    create(:monitoring_location, site_number: "40000010", usgs_monitoring_location_id: "USGS-40000010")
    io = StringIO.new
    progress = SyncProgress.new("NetworkRefreshBatchJob", io: io, logger: nil, every: 1)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert_equal 1, NetworkRefreshBatchJob.perform_now(1, progress: progress)
    end

    output = io.string
    assert_match(/NetworkRefreshBatchJob: starting/, output)
    assert_match(/pending=1 limit=1/, output)
    assert_match(/usgs_id=USGS-40000010 upstream=0 downstream=0 refreshed=1\/1/, output)
    assert_match(/refreshed=1 budget=1/, output)
  end

  test "skips when the NLDI rate limit circuit is open" do
    create(:monitoring_location, site_number: "40000004", usgs_monitoring_location_id: "USGS-40000004")
    Nldi::RateLimitCircuit.open!(ttl: 5.minutes)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert_equal 0, NetworkRefreshBatchJob.perform_now(10)
    end
  end

  test "skips on Sunday when catalog pause is enabled" do
    create(:monitoring_location, site_number: "40000003", usgs_monitoring_location_id: "USGS-40000003")

    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      assert_equal 0, NetworkRefreshBatchJob.perform_now(10)
    end
  end
end
