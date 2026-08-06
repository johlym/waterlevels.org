require "test_helper"

module Usgs
  class RateLimitCircuitTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "open? is false until tripped" do
      refute RateLimitCircuit.open?
      RateLimitCircuit.open!(ttl: 1.minute)
      assert RateLimitCircuit.open?
      RateLimitCircuit.clear!
      refute RateLimitCircuit.open?
    end

    test "circuits are isolated per key id" do
      RateLimitCircuit.open!(key_id: "history_1", ttl: 1.minute)
      assert RateLimitCircuit.open?("history_1")
      refute RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY)
      refute RateLimitCircuit.open?("history_2")
    end

    test "legacy unscoped cache key still opens tip circuit" do
      Rails.cache.write(RateLimitCircuit::LEGACY_KEY, true, expires_in: 1.minute)
      assert RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY)
      refute RateLimitCircuit.open?("history_1")
    end
  end
end
