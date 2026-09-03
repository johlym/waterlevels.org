require "test_helper"

module Nldi
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

    test "default ttl covers the rest of the UTC hour" do
      travel_to Time.utc(2026, 8, 31, 15, 50, 0) do
        assert_equal 10.minutes, RateLimitCircuit.default_ttl
      end
    end

    test "default ttl floors to five minutes late in the hour" do
      travel_to Time.utc(2026, 8, 31, 15, 59, 50) do
        assert_equal 5.minutes, RateLimitCircuit.default_ttl
      end
    end
  end
end
