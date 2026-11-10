require "test_helper"
require "sidekiq/api"

class PipelineSignalsTest < ActiveSupport::TestCase
  FakeQueue = Struct.new(:size, :latency)
  FakeStats = Struct.new(:retry_size, :dead_size, :scheduled_size)
  FakeProcess = Struct.new(:queues, :stopping) do
    def stopping?
      stopping
    end

    def [](key)
      queues if key.to_s == "queues"
    end
  end

  test "queue snapshot emits every data queue including empty ones" do
    emitted = []
    with_sidekiq(
      depths: { "backfill" => 4 },
      latencies: { "backfill" => 12.5 },
      workers: [ "backfill" ],
      stats: FakeStats.new(2, 1, 3)
    ) do
      with_singleton_method(Telemetry, :gauge, gauge_recorder(emitted)) do
        PipelineSignals.record_queues!
      end
    end

    queues = emitted.select { |event| event[:name] == "pipeline.queue" }
    assert_equal PipelineSignals::DATA_QUEUES.sort, queues.map { |event| event[:attrs][:queue] }.sort

    backfill = queues.find { |event| event[:attrs][:queue] == "backfill" }
    assert_equal "queue", backfill[:signal]
    assert_equal 4, backfill[:attrs][:"queue.depth"]
    assert_in_delta 12.5, backfill[:attrs][:"queue.latency_s"]
    assert_equal 1, backfill[:attrs][:"queue.workers"]

    sync = queues.find { |event| event[:attrs][:queue] == "sync" }
    assert_equal 0, sync[:attrs][:"queue.depth"]
    assert_in_delta 0.0, sync[:attrs][:"queue.latency_s"]
    assert_equal 0, sync[:attrs][:"queue.workers"]

    refute emitted.any? { |event| event[:attrs][:queue] == "notifications" }

    pressure = emitted.find { |event| event[:name] == "pipeline.pressure" }
    assert_equal "pressure", pressure[:signal]
    assert_equal 2, pressure[:attrs][:retry_size]
    assert_equal 1, pressure[:attrs][:dead_size]
    assert_equal 3, pressure[:attrs][:scheduled_size]
    assert pressure[:attrs].key?(:"circuit.tip")
    assert pressure[:attrs].key?(:history_keys_exhausted)
    assert pressure[:attrs].key?(:history_backfill_locks)
  end

  test "coverage emits national ratios and one event per state" do
    emitted = []
    aggregates = {
      station_count: 10,
      stations_history_ready: 5,
      stations_needing_history: 3,
      stations_needing_deep_history: 2,
      stations_daily_tip_refresh: 1,
      stations_missing_year_history: 4,
      per_state: [
        {
          state_code: "wa",
          station_count: 10,
          history_ready: 5,
          needing_history: 3,
          needing_deep_history: 2,
          daily_tip_refresh: 1,
          missing_year_history: 4,
          missing_continuous_anchor: 1,
          missing_continuous_tip: 2,
          missing_daily_tip: 1
        }
      ]
    }

    with_singleton_method(Telemetry, :gauge, gauge_recorder(emitted)) do
      PipelineSignals.record_coverage!(
        aggregates,
        tip_freshness: {
          current: 7,
          h1_plus: 1,
          h6_plus: 0,
          h24_plus: 0,
          h72_plus: 0,
          stale: 2
        },
        iv_repair_candidates: nil,
        iv_scar_candidates: 6
      )
    end

    assert_equal 2, emitted.size
    national = emitted.find { |event| event[:attrs][:scope] == "national" }
    assert_equal "pipeline.coverage", national[:name]
    assert_equal "coverage", national[:signal]
    assert_equal 10, national[:attrs][:stations]
    assert_equal 3, national[:attrs][:stations_needing_history]
    assert_equal 2, national[:attrs][:stations_needing_deep]
    assert_equal 1, national[:attrs][:stations_daily_tip_refresh]
    assert_equal 4, national[:attrs][:stations_missing_year]
    assert_equal 1, national[:attrs][:stations_missing_continuous_anchor]
    assert_in_delta 0.5, national[:attrs][:history_ready_ratio]
    assert_equal 7, national[:attrs][:tip_current]
    assert_equal 2, national[:attrs][:tip_stale]
    assert_equal 6, national[:attrs][:stations_needing_iv_scar]
    refute national[:attrs].key?(:stations_needing_iv_repair)
    refute national[:attrs].key?(:state)

    wa = emitted.find { |event| event[:attrs][:state] == "wa" }
    assert_equal "state", wa[:attrs][:scope]
    assert_equal 3, wa[:attrs][:stations_needing_history]
    assert_equal 1, wa[:attrs][:stations_daily_tip_refresh]
    refute wa[:attrs].key?(:history_ready_ratio)
    refute wa[:attrs].key?(:tip_stale)
    refute wa[:attrs].key?(:stations_needing_iv_scar)
  end

  private

  def gauge_recorder(emitted)
    lambda do |name, signal:, **attrs|
      emitted << { name: name, signal: signal, attrs: attrs }
    end
  end

  def with_sidekiq(depths:, latencies:, workers:, stats:)
    processes = [ FakeProcess.new(workers, false) ]
    queue_for = lambda do |name|
      FakeQueue.new(depths[name].to_i, latencies[name].to_f)
    end

    with_singleton_method(Sidekiq::Queue, :new, queue_for) do
      with_singleton_method(Sidekiq::ProcessSet, :new, ->(*) { processes }) do
        with_singleton_method(Sidekiq::Stats, :new, ->(*) { stats }) do
          yield
        end
      end
    end
  end

  def with_singleton_method(klass, name, implementation)
    singleton = klass.singleton_class
    original = singleton.instance_method(name)
    singleton.define_method(name, implementation)
    yield
  ensure
    singleton.define_method(name, original) if original
  end
end
