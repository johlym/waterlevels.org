require "test_helper"

module Nwps
  class ClientTest < ActiveSupport::TestCase
    test "gauge returns parsed JSON for a known site" do
      stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/01646500")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { lid: "BRKM2", usgsId: "01646500" }.to_json
        )

      body = Client.new(request_pause_ms: 0).gauge("01646500")
      assert_equal "BRKM2", body["lid"]
    end

    test "gauge returns nil on 404" do
      stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/99999999")
        .to_return(status: 404, body: '{"message":"Not Found"}')

      assert_nil Client.new(request_pause_ms: 0).gauge("99999999")
    end
  end
end
