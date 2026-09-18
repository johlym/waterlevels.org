require "test_helper"

module Nwps
  class ClientStageflowTest < ActiveSupport::TestCase
    test "stageflow returns observed series for a lid" do
      stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/ACRW1/stageflow")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            observed: {
              primaryName: "Stage",
              primaryUnits: "ft",
              data: [
                { validTime: "2026-09-18T03:15:00Z", primary: 1.3, secondary: -999 }
              ]
            }
          }.to_json
        )

      body = Client.new(request_pause_ms: 0).stageflow("ACRW1")
      assert_equal "Stage", body.dig("observed", "primaryName")
      assert_equal 1.3, body.dig("observed", "data", 0, "primary")
    end

    test "stageflow returns nil on 404" do
      stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges/ZZZZZ/stageflow")
        .to_return(status: 404, body: '{"message":"Not Found"}')

      assert_nil Client.new(request_pause_ms: 0).stageflow("ZZZZZ")
    end
  end
end
