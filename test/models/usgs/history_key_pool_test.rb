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
  end
end
