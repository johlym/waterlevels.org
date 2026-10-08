require "test_helper"

class Mcp::AuthTest < ActiveSupport::TestCase
  TOKEN = "cd" * 32

  setup do
    @previous = ENV["WATERLEVELS_MCP_TOKEN"]
  end

  teardown do
    if @previous.nil?
      ENV.delete("WATERLEVELS_MCP_TOKEN")
    else
      ENV["WATERLEVELS_MCP_TOKEN"] = @previous
    end
  end

  test "unset or short tokens are not configured" do
    ENV.delete("WATERLEVELS_MCP_TOKEN")
    assert_not Mcp::Auth.configured?

    ENV["WATERLEVELS_MCP_TOKEN"] = "secret"
    assert_not Mcp::Auth.configured?
    assert_not Mcp::Auth.bearer_matches?("Bearer secret")
  end

  test "bearer scheme is case-insensitive and digests are compared" do
    ENV["WATERLEVELS_MCP_TOKEN"] = TOKEN

    assert Mcp::Auth.configured?
    assert Mcp::Auth.bearer_matches?("Bearer #{TOKEN}")
    assert Mcp::Auth.bearer_matches?("bearer #{TOKEN}")
    assert_not Mcp::Auth.bearer_matches?("Bearer #{TOKEN}extra")
    assert_not Mcp::Auth.bearer_matches?("Token #{TOKEN}")
    assert_not Mcp::Auth.bearer_matches?(nil)
  end
end
