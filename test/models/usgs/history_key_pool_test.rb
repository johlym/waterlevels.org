require "test_helper"

module Usgs
  class HistoryKeyPoolTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @previous_env = {
        "USGS_API_KEY" => ENV["USGS_API_KEY"],
        "USGS_API_HISTORY_1_KEY" => ENV["USGS_API_HISTORY_1_KEY"],
        "USGS_API_HISTORY_2_KEY" => ENV["USGS_API_HISTORY_2_KEY"]
      }
    end

    teardown do
      Rails.cache = @previous_cache
      @previous_env.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    test "falls back to tip key when history keys are unset" do
      ENV["USGS_API_KEY"] = "tip-key"
      ENV.delete("USGS_API_HISTORY_1_KEY")
      ENV.delete("USGS_API_HISTORY_2_KEY")

      refute HistoryKeyPool.configured?
      entry = HistoryKeyPool.claim!
      assert_equal "tip-key", entry[:api_key]
      assert_equal RateLimitCircuit::TIP_KEY, entry[:circuit_key]
    end

    test "round-robins configured history keys and skips open circuits" do
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"

      assert HistoryKeyPool.configured?
      first = HistoryKeyPool.claim!
      second = HistoryKeyPool.claim!
      assert_equal %w[hist-1 hist-2], [ first[:api_key], second[:api_key] ].sort
      assert_equal %w[history_1 history_2], [ first[:circuit_key], second[:circuit_key] ].sort

      RateLimitCircuit.open!(key_id: "history_1", ttl: 1.minute)
      4.times do
        entry = HistoryKeyPool.claim!
        assert_equal "hist-2", entry[:api_key]
        assert_equal "history_2", entry[:circuit_key]
      end
    end

    test "exhausted? when every history circuit is open" do
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"
      RateLimitCircuit.open!(key_id: "history_1", ttl: 1.minute)
      RateLimitCircuit.open!(key_id: "history_2", ttl: 1.minute)

      assert HistoryKeyPool.exhausted?
      assert_raises(Client::RateLimitError) { HistoryKeyPool.claim! }
    end

    test "tip circuit open does not exhaust a configured history pool" do
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"
      RateLimitCircuit.open!(key_id: RateLimitCircuit::TIP_KEY, ttl: 1.minute)

      refute HistoryKeyPool.exhausted?
      assert_includes %w[hist-1 hist-2], HistoryKeyPool.claim![:api_key]
    end

    test "hourly_request_budget scales with available keys" do
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"
      assert_equal 2, HistoryKeyPool.available_count
      assert_equal 2000, HistoryKeyPool.hourly_request_budget

      RateLimitCircuit.open!(key_id: "history_1", ttl: 1.minute)
      assert_equal 1, HistoryKeyPool.available_count
      assert_equal 1000, HistoryKeyPool.hourly_request_budget
    end

    test "remaining_request_budget subtracts live hourly counters" do
      begin
        Redis.new(RedisConfig.options).ping
      rescue Redis::BaseError
        skip "Redis unavailable"
      end
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"
      HourlyRequestBudget.clear_all!

      travel_to Time.utc(2026, 8, 7, 15, 10, 0) do
        10.times { HourlyRequestBudget.record!("history_1") }
        assert_equal 1990, HistoryKeyPool.remaining_request_budget
      end
    ensure
      HourlyRequestBudget.clear_all!
    end

    test "soft-capped history key is excluded from available entries" do
      begin
        Redis.new(RedisConfig.options).ping
      rescue Redis::BaseError
        skip "Redis unavailable"
      end
      previous = ENV["USGS_HOURLY_SOFT_CAP"]
      ENV["USGS_HOURLY_SOFT_CAP"] = "2"
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"
      HourlyRequestBudget.clear_all!

      travel_to Time.utc(2026, 8, 7, 15, 10, 0) do
        2.times { HourlyRequestBudget.record!("history_1") }
        available = HistoryKeyPool.available_entries.map { |e| e[:circuit_key] }
        assert_equal [ "history_2" ], available
      end
    ensure
      HourlyRequestBudget.clear_all!
      if previous.nil?
        ENV.delete("USGS_HOURLY_SOFT_CAP")
      else
        ENV["USGS_HOURLY_SOFT_CAP"] = previous
      end
    end
  end
end
