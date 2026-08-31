require "test_helper"

module Nldi
  class ClientTest < ActiveSupport::TestCase
    test "requests navigation sites without an API key" do
      stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/linked-data/nwissite/USGS-12113000/navigation/UM/nwissite})
        .with { |request|
          assert_nil request.headers["X-Api-Key"]
          assert_equal "true", request.uri.query_values["excludeGeometry"]
          true
        }
        .to_return(
          status: 200,
          body: { type: "FeatureCollection", features: [ { id: "USGS-12113000" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      features = Client.new(request_pause_ms: 0).navigate_sites("USGS-12113000", mode: "UM", distance_km: 80)

      assert_equal 1, features.size
      assert_equal "USGS-12113000", features.first["id"]
    end

    test "404 returns an empty feature list" do
      stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/linked-data/nwissite/USGS-00000000/navigation/DM/nwissite})
        .to_return(status: 404, body: "", headers: { "Content-Type" => "application/json" })

      assert_empty Client.new(request_pause_ms: 0).navigate_sites("USGS-00000000", mode: "DM", distance_km: 80)
    end

    test "pauses between consecutive requests when configured" do
      stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
        .to_return(
          status: 200,
          body: { type: "FeatureCollection", features: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      slept = []
      client = Client.new(request_pause_ms: 50)
      client.define_singleton_method(:sleep_pause) { |seconds| slept << seconds }

      client.navigate_sites("USGS-12113000", mode: "UM", distance_km: 80)
      client.navigate_flowlines("USGS-12113000", mode: "UM", distance_km: 80)

      assert_equal [ 0.05 ], slept
    end

    test "429 trips the NLDI circuit and does not retry" do
      stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
        .to_return(
          status: 429,
          body: { error: { code: "OVER_RATE_LIMIT", message: "You have exceeded your rate limit." } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_raises(Client::RateLimitError) do
        Client.new(request_pause_ms: 0).navigate_sites("USGS-03343400", mode: "UM", distance_km: 80)
      end
      assert RateLimitCircuit.open?
      assert_raises(Client::RateLimitError) do
        Client.new(request_pause_ms: 0).navigate_sites("USGS-03343400", mode: "DM", distance_km: 80)
      end
    ensure
      RateLimitCircuit.clear!
    end

    test "does not send an API key on flowline navigation" do
      stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/linked-data/nwissite/USGS-12113000/navigation/DM/flowlines})
        .with { |request| assert_nil request.headers["X-Api-Key"]; true }
        .to_return(
          status: 200,
          body: { type: "FeatureCollection", features: [ { id: 1, properties: { nhdplus_comid: 1 } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      features = Client.new(request_pause_ms: 0).navigate_flowlines("USGS-12113000", mode: "DM", distance_km: 80)
      assert_equal "1", features.first["id"].to_s
    end
  end
end
