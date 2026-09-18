require "test_helper"

module Usace
  class ClientTest < ActiveSupport::TestCase
    test "location fetches CWMS JSON document" do
      stub_request(:get, "https://cwms-data.usace.army.mil/cwms-data/locations/Raystown")
        .with(query: hash_including("office" => "NAB", "format" => "json"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "name" => "Raystown",
            "office-id" => "NAB",
            "public-name" => "Raystown Lake"
          }.to_json
        )

      body = Client.new(request_pause_ms: 0).location(name: "Raystown", office: "NAB")
      assert_equal "Raystown", body["name"]
    end

    test "each_timeseries_value yields rows and follows next-page" do
      stub_request(:get, "https://cwms-data.usace.army.mil/cwms-data/timeseries")
        .with(query: hash_including("name" => "Raystown.Elev.Ave.~1Day.1Day.Best-NAB", "page-size" => "2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "values" => [ [ 1_700_000_000_000, 786.3, 0 ] ],
            "next-page" => "CURSOR2",
            "total" => 2
          }.to_json
        )
      stub_request(:get, "https://cwms-data.usace.army.mil/cwms-data/timeseries")
        .with(query: hash_including("page" => "CURSOR2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "values" => [ [ 1_700_086_400_000, 786.4, 0 ] ],
            "next-page" => nil,
            "total" => 2
          }.to_json
        )

      rows = []
      Client.new(request_pause_ms: 0).each_timeseries_value(
        name: "Raystown.Elev.Ave.~1Day.1Day.Best-NAB",
        office: "NAB",
        begin_at: Time.utc(2023, 11, 14),
        end_at: Time.utc(2023, 11, 16),
        page_size: 2
      ) { |t, v, q| rows << [ t.to_i, v, q ] }

      assert_equal 2, rows.size
      assert_in_delta 786.3, rows[0][1], 0.001
      assert_in_delta 786.4, rows[1][1], 0.001
    end

    test "404 raises NotFoundError" do
      stub_request(:get, "https://cwms-data.usace.army.mil/cwms-data/locations/Missing")
        .with(query: hash_including("office" => "NAB"))
        .to_return(status: 404, body: '{"message":"Not Found"}')

      assert_raises(Client::NotFoundError) do
        Client.new(request_pause_ms: 0).location(name: "Missing", office: "NAB")
      end
    end
  end
end
