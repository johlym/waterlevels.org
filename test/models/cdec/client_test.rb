require "test_helper"

module Cdec
  class ClientTest < ActiveSupport::TestCase
    test "readings parses JSONDataServlet text/plain body" do
      stub_request(:get, "https://cdec.water.ca.gov/dynamicapp/req/JSONDataServlet")
        .with(query: hash_including("Stations" => "ORO", "SensorNums" => "6", "dur_code" => "D"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "text/plain" },
          body: [
            { "stationId" => "ORO", "date" => "2026-9-17 00:00", "value" => 770.3, "units" => "FEET" },
            { "stationId" => "ORO", "date" => "2026-9-18 00:00", "value" => -9999, "units" => "FEET" }
          ].to_json
        )

      rows = []
      Client.new(request_pause_ms: 0).each_reading(
        station_id: "ORO",
        sensor_num: 6,
        start_on: Date.new(2026, 9, 17),
        end_on: Date.new(2026, 9, 18)
      ) { |row| rows << row }

      assert_equal 2, rows.size
      assert_in_delta 770.3, rows[0]["value"], 0.001
      assert Client.missing_value?(-9999)
      assert_not Client.missing_value?(770.3)
    end

    test "404 raises NotFoundError" do
      stub_request(:get, "https://cdec.water.ca.gov/dynamicapp/req/JSONDataServlet")
        .with(query: hash_including("Stations" => "ZZZ"))
        .to_return(status: 404, body: "missing")

      assert_raises(Client::NotFoundError) do
        Client.new(request_pause_ms: 0).readings(
          station_id: "ZZZ",
          sensor_num: 6,
          start_on: Date.new(2026, 9, 1),
          end_on: Date.new(2026, 9, 2)
        )
      end
    end
  end
end
