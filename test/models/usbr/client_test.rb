require "test_helper"

module Usbr
  class ClientTest < ActiveSupport::TestCase
    test "location fetches RISE JSON:API document" do
      stub_request(:get, "https://data.usbr.gov/rise/api/location/3514")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/vnd.api+json" },
          body: {
            "data" => {
              "type" => "Location",
              "attributes" => { "_id" => 3514, "locationName" => "Lake Mead Hoover Dam and Powerplant" }
            }
          }.to_json
        )

      body = Client.new(request_pause_ms: 0).location(3514)
      assert_equal 3514, body.dig("data", "attributes", "_id")
    end

    test "each_result yields attribute hashes across pages" do
      stub_request(:get, "https://data.usbr.gov/rise/api/result")
        .with(query: hash_including("itemId" => "6123", "page" => "1"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/vnd.api+json" },
          body: {
            "meta" => { "totalItems" => 2, "itemsPerPage" => 1, "currentPage" => 1 },
            "data" => [
              {
                "attributes" => {
                  "dateTime" => "2026-09-16T07:00:00+00:00",
                  "result" => 1038.5,
                  "itemId" => 6123
                }
              }
            ]
          }.to_json
        )
      stub_request(:get, "https://data.usbr.gov/rise/api/result")
        .with(query: hash_including("itemId" => "6123", "page" => "2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/vnd.api+json" },
          body: {
            "meta" => { "totalItems" => 2, "itemsPerPage" => 1, "currentPage" => 2 },
            "data" => [
              {
                "attributes" => {
                  "dateTime" => "2026-09-15T07:00:00+00:00",
                  "result" => 1038.66,
                  "itemId" => 6123
                }
              }
            ]
          }.to_json
        )

      values = []
      Client.new(request_pause_ms: 0).each_result(6123, items_per_page: 1) { |attrs| values << attrs["result"] }
      assert_equal [ 1038.5, 1038.66 ], values
    end

    test "404 raises NotFoundError" do
      stub_request(:get, "https://data.usbr.gov/rise/api/location/0")
        .to_return(status: 404, body: '{"title":"Not Found"}')

      assert_raises(Client::NotFoundError) { Client.new(request_pause_ms: 0).location(0) }
    end
  end
end
