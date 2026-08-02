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
  end
end
