require "test_helper"

class IvRepairScarJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @previous_env = {
      "USGS_API_HISTORY_IVREPAIR2_KEY" => ENV["USGS_API_HISTORY_IVREPAIR2_KEY"],
      "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"],
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_IVREPAIR2_KEY"] = "hist-iv-repair2"
    ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
  end

  teardown do
    Rails.cache = @previous_cache
    @previous_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "runs on the isolated iv_repair_scar queue" do
    assert_equal "iv_repair_scar", IvRepairScarJob.new.queue_name
  end

  test "enqueue claims shared lock and requires iv_repair2 key" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert IvRepairScarJob.enqueue(99)
      assert_enqueued_with(job: IvRepairScarJob, args: [ 99 ])
      refute IvRepairScarJob.enqueue(99)
      assert_equal :locked_or_cooling, IvRepairScarJob.enqueue_block_reason(99)
    end
  end

  test "enqueue returns false when iv_repair2 key is unset" do
    ENV.delete("USGS_API_HISTORY_IVREPAIR2_KEY")
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      assert_no_enqueued_jobs only: IvRepairScarJob do
        refute IvRepairScarJob.enqueue(99)
      end
      assert_equal :iv_repair2_key_unconfigured, IvRepairScarJob.enqueue_block_reason(99)
    end
  end

  test "enqueue returns false when iv_repair2 circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair2", ttl: 1.minute)
      assert_no_enqueued_jobs only: IvRepairScarJob do
        refute IvRepairScarJob.enqueue(99)
      end
    end
  end

  test "empty USGS response parks the unfillable scar so the candidate count can fall" do
    location = create(:monitoring_location, site_number: "30000401")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    daily_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
    peaks_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 5.days.ago
      )
      seed_continuous_coverage!(
        series,
        from: 3.days.ago,
        to: 1.hour.ago
      )

      assert location.reload.needs_iv_scar_repair?
      assert_includes MonitoringLocation.iv_scar_candidate_ids, location.id

      assert IvRepairLock.claim!(location.id)
      IvRepairScarJob.perform_now(location.id)

      assert_requested :get, %r{collections/continuous/items}
      assert_not_requested daily_stub
      assert_not_requested peaks_stub
      refute location.reload.needs_iv_scar_repair?
      refute_includes MonitoringLocation.iv_scar_candidate_ids, location.id
      refute IvRepairLock.cooling_down?(location.id)
      assert location.known_missing_usgs_iv?
      assert_in_delta 7.days.from_now.to_i, location.usgs_iv_gap_recheck_at.to_i, 2

      series.reload
      assert series.iv_scar_checked_at.present?
      assert_operator series.continuous_max_gap_seconds, :>, HistoryIngestion.continuous_gap_threshold.to_i
    end
  end

  test "filling the interior hole clears the scar check and candidate flag" do
    location = create(:monitoring_location, site_number: "30000402")
    series = create(:time_series, monitoring_location: location, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 5.days.ago
      )
      seed_continuous_coverage!(
        series,
        from: 3.days.ago,
        to: 1.hour.ago
      )

      fill_from = 5.days.ago
      fill_to = 3.days.ago
      features = []
      t = fill_from
      while t <= fill_to
        features << {
          id: t.to_i.to_s,
          properties: {
            time_series_id: series.usgs_time_series_id,
            parameter_code: series.parameter_code,
            time: t.utc.iso8601,
            value: 2.5
          }
        }
        t += 1.hour
      end

      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: { features: features, links: [] }.to_json
        )

      assert IvRepairLock.claim!(location.id)
      IvRepairScarJob.perform_now(location.id)

      refute location.reload.needs_iv_scar_repair?
      refute_includes MonitoringLocation.iv_scar_candidate_ids, location.id
      series.reload
      assert_nil series.iv_scar_checked_at
      assert_operator series.continuous_max_gap_seconds, :<=, HistoryIngestion.continuous_gap_threshold.to_i
    end
  end

  test "enqueue still works when tip iv_repair circuit is open" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      Usgs::RateLimitCircuit.open!(key_id: "history_iv_repair", ttl: 1.minute)
      assert IvRepairScarJob.enqueue(199)
      assert_enqueued_with(job: IvRepairScarJob, args: [ 199 ])
    end
  end
end
