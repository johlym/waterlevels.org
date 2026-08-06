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

    test "purge_tags retries rate limit errors with backoff" do
      sleeps = []
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/zone-1/purge_cache")
        .to_return(
          { status: 429, body: { success: false, errors: [ { message: "Unable to purge, rate limit reached. Please wait and consider throttling your request speed" } ] }.to_json, headers: { "Content-Type" => "application/json" } },
          { status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" } }
        )

      purger = Cloudflare::CachePurge.new(
        api_token: "token-1",
        zone_id: "zone-1",
        sleeper: ->(seconds) { sleeps << seconds }
      )
      assert_equal :purged, purger.purge_tags([ "home" ])
      assert_equal [ Cloudflare::CachePurge::BASE_BACKOFF ], sleeps
    end

    test "purge_tags gives up after repeated rate limits" do
      sleeps = []
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/zone-1/purge_cache")
        .to_return(
          status: 429,
          body: { success: false, errors: [ { message: "Unable to purge, rate limit reached" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      purger = Cloudflare::CachePurge.new(
        api_token: "token-1",
        zone_id: "zone-1",
        sleeper: ->(seconds) { sleeps << seconds }
      )
      error = assert_raises(Cloudflare::CachePurge::RateLimited) { purger.purge_tags([ "home" ]) }
      assert_match(/rate limit/i, error.message)
      assert_equal Cloudflare::CachePurge::MAX_ATTEMPTS - 1, sleeps.size
    end
  end
end
