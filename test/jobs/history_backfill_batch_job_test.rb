require "test_helper"

class HistoryBackfillBatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    # Parallel workers share Redis request counters. A depleted tip-key budget
    # makes phase-1 budget 0 (cost 1000) while deep (cost 2) still enqueues.
    clear_shared_request_budget!
  end

  teardown do
    Rails.cache = @previous_cache
    clear_shared_request_budget!
  end

  test "enqueues history jobs for locations needing backfill" do
    needs = create(:monitoring_location, site_number: "30000001")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    complete = create(:monitoring_location, site_number: "30000002")
    series = create(:time_series, monitoring_location: complete, selected_for_display: true)
    ContinuousObservation.create!(
      time_series: series,
      observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
      value: 0.9
    )
    ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)
    DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
    DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      assert_enqueued_with(job: HistoryBackfillJob, args: [ needs.id, "1y" ]) do
        HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end

  test "skips cooling stations and advances to later candidates" do
    stuck = create(:monitoring_location, site_number: "30000010")
    create(:time_series, monitoring_location: stuck, selected_for_display: true)

    ready = create(:monitoring_location, site_number: "30000011")
    create(:time_series, monitoring_location: ready, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      HistoryBackfillLock.cooldown!(stuck.id)

      assert_enqueued_with(job: HistoryBackfillJob, args: [ ready.id, "1y" ]) do
        assert_equal 1, HistoryBackfillBatchJob.perform_now(1)
      end
      refute HistoryBackfillJob.enqueue(stuck.id)
    end
  end

  test "skips enqueueing on Sunday for catalog sync budget" do
    needs = create(:monitoring_location, site_number: "30000020")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-02 12:00:00") do # Sunday
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end

  test "skips enqueueing when USGS rate limit circuit is open" do
    needs = create(:monitoring_location, site_number: "30000021")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      Usgs::RateLimitCircuit.open!(ttl: 1.minute)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
      end
    end
  end

  test "retries when database read-only circuit is open without enqueueing stations" do
    needs = create(:monitoring_location, site_number: "30000022")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      DatabaseReadOnlyCircuit.open!(ttl: 1.minute)
      assert_no_enqueued_jobs only: HistoryBackfillJob do
        assert_enqueued_with(job: HistoryBackfillBatchJob) do
          HistoryBackfillBatchJob.perform_now(10)
        end
      end
    end
  end

  test "enqueues deep 3y jobs for year-ready stations after phase-1 budget" do
    cold = create(:monitoring_location, site_number: "30000030")
    create(:time_series, monitoring_location: cold, selected_for_display: true)

    year_ready = create(:monitoring_location, site_number: "30000031")
    series = create(:time_series, monitoring_location: year_ready, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      ContinuousObservation.create!(
        time_series: series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
      ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
      DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)

      with_env("HISTORY_DEEP_BACKFILL_BATCH" => "5") do
        assert_enqueued_with(job: HistoryBackfillJob, args: [ cold.id, "1y" ]) do
          assert_enqueued_with(job: HistoryBackfillJob, args: [ year_ready.id, "3y" ]) do
            assert_equal 2, HistoryBackfillBatchJob.perform_now(10)
          end
        end
      end
    end
  end

  test "skips deep enqueues when HISTORY_DEEP_BACKFILL_BATCH is zero" do
    year_ready = create(:monitoring_location, site_number: "30000032")
    series = create(:time_series, monitoring_location: year_ready, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      ContinuousObservation.create!(
        time_series: series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
      ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
      DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)

      with_env("HISTORY_DEEP_BACKFILL_BATCH" => "0") do
        assert_no_enqueued_jobs only: HistoryBackfillJob do
          assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
        end
      end
    end
  end

  test "scales default phase-1 budget by available history keys" do
    locations = 3.times.map do |i|
      loc = create(:monitoring_location, site_number: format("3000004%d", i))
      create(:time_series, monitoring_location: loc, selected_for_display: true)
      loc
    end

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      with_env(
        "USGS_API_HISTORY_1_KEY" => "hist-1",
        "USGS_API_HISTORY_2_KEY" => "hist-2",
        "HISTORY_BACKFILL_BATCH" => "1",
        "HISTORY_DEEP_BACKFILL_BATCH" => "0"
      ) do
        # 1 station/key × 2 keys = 2 enqueues (third candidate waits).
        assert_equal 2, HistoryBackfillBatchJob.perform_now
        enqueued_ids = enqueued_jobs
          .select { |job| job[:job] == HistoryBackfillJob }
          .map { |job| job[:args].first }
        assert_equal 2, enqueued_ids.size
        assert_empty enqueued_ids - locations.map(&:id)
      end
    end
  end

  test "deep budget uses leftover request capacity after phase-1" do
    cold = create(:monitoring_location, site_number: "30000050")
    create(:time_series, monitoring_location: cold, selected_for_display: true)

    year_ready = create(:monitoring_location, site_number: "30000051")
    series = create(:time_series, monitoring_location: year_ready, selected_for_display: true)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do # Monday
      ContinuousObservation.create!(
        time_series: series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
      ContinuousObservation.create!(time_series: series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: series, observed_on: 11.months.ago.to_date, value: 1.1)
      DailyObservation.create!(time_series: series, observed_on: Date.current, value: 1.2)

      # One fallback key, phase-1 cost 1000 ⇒ one cold station consumes the whole
      # hourly request budget, so deep must stay at zero despite a high ceiling.
      with_env(
        "HISTORY_BACKFILL_BATCH" => "1",
        "HISTORY_DEEP_BACKFILL_BATCH" => "400",
        "HISTORY_PHASE1_REQUESTS_PER_STATION" => "1000"
      ) do
        assert_enqueued_with(job: HistoryBackfillJob, args: [ cold.id, "1y" ]) do
          assert_equal 1, HistoryBackfillBatchJob.perform_now
        end
        refute enqueued_jobs.any? { |job|
          job[:job] == HistoryBackfillJob && job[:args] == [ year_ready.id, "3y" ]
        }
      end
    end
  end

  test "skips when remaining hourly request budget is exhausted" do
    begin
      Redis.new(RedisConfig.options).ping
    rescue Redis::BaseError
      skip "Redis unavailable"
    end

    needs = create(:monitoring_location, site_number: "30000060")
    create(:time_series, monitoring_location: needs, selected_for_display: true)

    with_env("USGS_HOURLY_SOFT_CAP" => "1") do
      travel_to Time.utc(2026, 8, 3, 12, 0, 0) do # Monday
        Usgs::HourlyRequestBudget.clear_all!
        # Fallback tip key is the only history entry when history keys are unset.
        Usgs::HourlyRequestBudget.record!(Usgs::RateLimitCircuit::TIP_KEY)

        assert_no_enqueued_jobs only: HistoryBackfillJob do
          assert_equal 0, HistoryBackfillBatchJob.perform_now(10)
        end
      end
    ensure
      Usgs::HourlyRequestBudget.clear_all!
    end
  end

  private

  def clear_shared_request_budget!
    Usgs::HourlyRequestBudget.clear_all!
  rescue Redis::BaseError
    nil
  end

  def with_env(vars)
    previous = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
