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
  end
end
