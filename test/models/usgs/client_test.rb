require "test_helper"

module Usgs
  class ClientTest < ActiveSupport::TestCase
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
  end
end
