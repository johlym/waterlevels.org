require "test_helper"

module Cloudflare
  class CachePurgeTest < ActiveSupport::TestCase
    test "purge_tags no-ops when credentials are unset" do
      purger = Cloudflare::CachePurge.new(api_token: nil, zone_id: nil)
      assert_equal :skipped, purger.purge_tags([ "home" ])
    end

    test "purge_tags posts batches to the Cloudflare API" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/zone-1/purge_cache")
        .with { |req|
          body = JSON.parse(req.body)
          assert_equal [ "home", "gauges" ], body["tags"]
          assert_equal "Bearer token-1", req.headers["Authorization"]
          true
        }
        .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

      purger = Cloudflare::CachePurge.new(api_token: "token-1", zone_id: "zone-1")
      assert_equal :purged, purger.purge_tags([ "home", "gauges", "home" ])
    end

    test "purge_tags raises on API failure" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/zone-1/purge_cache")
        .to_return(
          status: 400,
          body: { success: false, errors: [ { message: "bad tag" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      purger = Cloudflare::CachePurge.new(api_token: "token-1", zone_id: "zone-1")
      error = assert_raises(Cloudflare::CachePurge::Error) { purger.purge_tags([ "home" ]) }
      assert_match(/bad tag/, error.message)
    end
  end
end
