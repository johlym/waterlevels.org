require "test_helper"

class EdgeCachePurgeJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    EdgeCachePurgeBuffer.backend = EdgeCachePurgeBuffer::MemoryBackend.new
  end

  teardown do
    EdgeCachePurgeBuffer.reset!
  end

  test "perform drains the buffer and clears the flush lock" do
    EdgeCachePurgeBuffer.add(%w[gauge:1 gauges])
    assert EdgeCachePurgeBuffer.schedule_flush!(delay: 0)

    purge = stub_request(:post, %r{api\.cloudflare\.com/client/v4/zones/.+/purge_cache})
      .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

    previous_token = ENV["CLOUDFLARE_API_TOKEN"]
    previous_zone = ENV["CLOUDFLARE_ZONE_ID"]
    ENV["CLOUDFLARE_API_TOKEN"] = "token-test"
    ENV["CLOUDFLARE_ZONE_ID"] = "zone-test"
    begin
      EdgeCachePurgeJob.perform_now
    ensure
      previous_token ? ENV["CLOUDFLARE_API_TOKEN"] = previous_token : ENV.delete("CLOUDFLARE_API_TOKEN")
      previous_zone ? ENV["CLOUDFLARE_ZONE_ID"] = previous_zone : ENV.delete("CLOUDFLARE_ZONE_ID")
    end

    assert_requested purge
    assert_empty EdgeCachePurgeBuffer.drain
    assert EdgeCachePurgeBuffer.schedule_flush!(delay: 0)
  end
end
