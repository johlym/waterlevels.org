require "test_helper"

class NetworkRefreshBatchJobTest < ActiveSupport::TestCase
  setup do
    stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
      .to_return(status: 404, body: "", headers: { "Content-Type" => "application/json" })
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

  test "skips on Sunday when catalog pause is enabled" do
    create(:monitoring_location, site_number: "40000003", usgs_monitoring_location_id: "USGS-40000003")

    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      assert_equal 0, NetworkRefreshBatchJob.perform_now(10)
    end
  end
end
