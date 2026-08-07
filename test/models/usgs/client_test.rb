require "test_helper"

module Usgs
  class ClientTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "requests collection items under the ogcapi base path" do
      stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
        .with(query: hash_including("f" => "json", "limit" => "1", "state_code" => "53"))
        .to_return(
          status: 200,
          body: { features: [], links: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      features = []
      Client.new(api_key: nil).each_collection_item("monitoring-locations", limit: 1, state_code: "53") do |item|
        features << item
      end

      assert_empty features
      assert_requested(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
    end

    test "pauses between paginated requests when pause is configured" do
      page1 = {
        features: [ { id: "1", properties: { name: "a" }, geometry: { type: "Point", coordinates: [ -122.0, 47.0 ] } } ],
        links: [ { rel: "next", href: "https://api.waterdata.usgs.gov/ogcapi/v0/collections/monitoring-locations/items?cursor=2" } ]
      }
      page2 = { features: [], links: [] }

      stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items\?})
        .to_return(status: 200, body: page1.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.waterdata.usgs.gov/ogcapi/v0/collections/monitoring-locations/items?cursor=2")
        .to_return(status: 200, body: page2.to_json, headers: { "Content-Type" => "application/json" })

      slept = []
      client = Client.new(api_key: nil, request_pause_ms: 50)
      client.define_singleton_method(:sleep_pause) { |seconds| slept << seconds }
      client.each_collection_item("monitoring-locations", limit: 1) { }

      assert_equal [ 0.05 ], slept
    end

    test "429 opens the rate limit circuit and fails without retrying" do
      stub = stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
        .to_return(status: 429, body: "rate limited", headers: { "Content-Type" => "text/plain" })

      assert_raises(Client::RateLimitError) do
        Client.new(api_key: nil).each_collection_item("monitoring-locations", limit: 1) { }
      end

      assert RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY)
      assert_requested(stub, times: 1)
    end

    test "successful requests increment the hourly request budget counter" do
      begin
        Redis.new(RedisConfig.options).ping
      rescue Redis::BaseError
        skip "Redis unavailable"
      end
      HourlyRequestBudget.clear!(RateLimitCircuit::TIP_KEY)

      stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
        .to_return(
          status: 200,
          body: { features: [], links: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      Client.new(api_key: nil).each_collection_item("monitoring-locations", limit: 1) { }
      assert_equal 1, HourlyRequestBudget.used(RateLimitCircuit::TIP_KEY)
    ensure
      HourlyRequestBudget.clear!(RateLimitCircuit::TIP_KEY) if defined?(HourlyRequestBudget)
    end

    test "soft-capped key does not call USGS" do
      begin
        Redis.new(RedisConfig.options).ping
      rescue Redis::BaseError
        skip "Redis unavailable"
      end
      previous = ENV["USGS_HOURLY_SOFT_CAP"]
      ENV["USGS_HOURLY_SOFT_CAP"] = "1"
      HourlyRequestBudget.clear!("history_1")
      HourlyRequestBudget.record!("history_1")
      stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov})

      assert_raises(Client::RateLimitError) do
        Client.new(api_key: "hist-1", circuit_key: "history_1")
          .each_collection_item("monitoring-locations", limit: 1) { }
      end

      assert_not_requested(stub)
      assert RateLimitCircuit.open?("history_1")
    ensure
      HourlyRequestBudget.clear!("history_1") if defined?(HourlyRequestBudget)
      if previous.nil?
        ENV.delete("USGS_HOURLY_SOFT_CAP")
      else
        ENV["USGS_HOURLY_SOFT_CAP"] = previous
      end
    end

    test "429 on a history client only trips that history circuit" do
      stub = stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
        .to_return(status: 429, body: "rate limited", headers: { "Content-Type" => "text/plain" })

      assert_raises(Client::RateLimitError) do
        Client.new(api_key: "hist-1", circuit_key: "history_1")
          .each_collection_item("monitoring-locations", limit: 1) { }
      end

      assert RateLimitCircuit.open?("history_1")
      refute RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY)
      assert_requested(stub, times: 1)
    end

    test "does not call USGS while the rate limit circuit is open" do
      RateLimitCircuit.open!(ttl: 1.minute)
      stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov})

      assert_raises(Client::RateLimitError) do
        Client.new(api_key: nil).each_collection_item("monitoring-locations", limit: 1) { }
      end

      assert_not_requested(stub)
    end

    test "for_tip and for_history select distinct keys when history keys are set" do
      previous = {
        "USGS_API_KEY" => ENV["USGS_API_KEY"],
        "USGS_API_HISTORY_1_KEY" => ENV["USGS_API_HISTORY_1_KEY"],
        "USGS_API_HISTORY_2_KEY" => ENV["USGS_API_HISTORY_2_KEY"]
      }
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_1_KEY"] = "hist-1"
      ENV["USGS_API_HISTORY_2_KEY"] = "hist-2"

      tip = Client.for_tip
      history = Client.for_history

      assert_equal RateLimitCircuit::TIP_KEY, tip.circuit_key
      assert_includes %w[history_1 history_2], history.circuit_key
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
  end
end
