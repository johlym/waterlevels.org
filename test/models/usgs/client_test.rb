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

    test "429 on a history client only trips that purpose circuit" do
      stub = stub_request(:get, %r{\Ahttps://api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
        .to_return(status: 429, body: "rate limited", headers: { "Content-Type" => "text/plain" })

      assert_raises(Client::RateLimitError) do
        Client.new(api_key: "hist-daily", circuit_key: "history_daily")
          .each_collection_item("monitoring-locations", limit: 1) { }
      end

      assert RateLimitCircuit.open?("history_daily")
      refute RateLimitCircuit.open?(RateLimitCircuit::TIP_KEY)
      refute RateLimitCircuit.open?("history_continuous")
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

    test "for_tip and for_history pin distinct purpose keys" do
      previous = {
        "USGS_API_KEY" => ENV["USGS_API_KEY"],
        "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
        "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
        "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"],
        "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"]
      }
      ENV["USGS_API_KEY"] = "tip-key"
      ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
      ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
      ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"
      ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"

      tip = Client.for_tip
      continuous = Client.for_history(:continuous)
      daily = Client.for_history(:daily)
      peaks = Client.for_history(:peaks)
      iv_repair = Client.for_history(:iv_repair)

      assert_equal RateLimitCircuit::TIP_KEY, tip.circuit_key
      assert_equal "history_continuous", continuous.circuit_key
      assert_equal "history_daily", daily.circuit_key
      assert_equal "history_peaks", peaks.circuit_key
      assert_equal "history_iv_repair", iv_repair.circuit_key
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
  end
end
