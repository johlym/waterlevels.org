require "test_helper"

class Mcp::AuthTest < ActiveSupport::TestCase
  TOKEN = "cd" * 32
  FRONT_DOOR = "mcp-auth-front-door"

  setup do
    @previous = ENV["WATERLEVELS_MCP_TOKEN"]
    @previous_front_door = ENV["WATERLEVELS_MCP_FRONT_DOOR"]
    ENV["WATERLEVELS_MCP_FRONT_DOOR"] = FRONT_DOOR
  end

  teardown do
    restore_env("WATERLEVELS_MCP_TOKEN", @previous)
    restore_env("WATERLEVELS_MCP_FRONT_DOOR", @previous_front_door)
  end

  test "unset or short token or front door is not configured" do
    ENV.delete("WATERLEVELS_MCP_TOKEN")
    assert_not Mcp::Auth.configured?

    ENV["WATERLEVELS_MCP_TOKEN"] = "secret"
    assert_not Mcp::Auth.configured?
    assert_not Mcp::Auth.bearer_matches?("Bearer secret")

    ENV["WATERLEVELS_MCP_TOKEN"] = TOKEN
    ENV.delete("WATERLEVELS_MCP_FRONT_DOOR")
    assert_not Mcp::Auth.configured?

    ENV["WATERLEVELS_MCP_FRONT_DOOR"] = "too-short"
    assert_not Mcp::Auth.configured?
    assert_not Mcp::Auth.front_door_matches?("too-short")
  end

  test "bearer scheme is case-insensitive and digests are compared" do
    ENV["WATERLEVELS_MCP_TOKEN"] = TOKEN

    assert Mcp::Auth.configured?
    assert Mcp::Auth.bearer_matches?("Bearer #{TOKEN}")
    assert Mcp::Auth.bearer_matches?("bearer #{TOKEN}")
    assert_not Mcp::Auth.bearer_matches?("Bearer #{TOKEN}extra")
    assert_not Mcp::Auth.bearer_matches?("Token #{TOKEN}")
    assert_not Mcp::Auth.bearer_matches?(nil)
    assert Mcp::Auth.front_door_matches?(FRONT_DOOR)
    assert_not Mcp::Auth.front_door_matches?("other-front-door-val")
    assert_not Mcp::Auth.front_door_matches?(nil)
  end

  private

  def restore_env(key, previous)
    if previous.nil?
      ENV.delete(key)
    else
      ENV[key] = previous
    end
  end
end
