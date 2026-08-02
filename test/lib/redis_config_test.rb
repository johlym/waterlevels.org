require "test_helper"

class RedisConfigTest < ActiveSupport::TestCase
  test "options include self-signed cert verify mode" do
    opts = RedisConfig.options(default_url: "rediss://example.internal:6379")
    assert_equal "rediss://example.internal:6379", opts[:url]
    assert_equal OpenSSL::SSL::VERIFY_NONE, opts[:ssl_params][:verify_mode]
  end
end
