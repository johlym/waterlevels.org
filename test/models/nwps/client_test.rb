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

    test "gauges requires a region and scopes the list by that region's bbox" do
      bbox = ListRegions.bbox_for("conus_pacific")
      stub_request(:get, "https://api.water.noaa.gov/nwps/v1/gauges")
        .with(
          query: {
            "bbox.xmin" => bbox.fetch(:xmin).to_s,
            "bbox.ymin" => bbox.fetch(:ymin).to_s,
            "bbox.xmax" => bbox.fetch(:xmax).to_s,
            "bbox.ymax" => bbox.fetch(:ymax).to_s,
            "srid" => "EPSG_4326"
          }
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            gauges: [
              { lid: "ACAW1", status: { observed: { floodCategory: "no_flooding" } } }
            ]
          }.to_json
        )

      list = Client.new(request_pause_ms: 0).gauges(region: "conus_pacific")
      assert_equal 1, list.size
      assert_equal "ACAW1", list.first["lid"]
    end

    test "gauges rejects a missing or unknown region" do
      assert_raises(ArgumentError) { Client.new(request_pause_ms: 0).gauges(region: nil) }
      assert_raises(ArgumentError) { Client.new(request_pause_ms: 0).gauges(region: "atlantis") }
    end
  end
end
