require "test_helper"

class Mcp::GateTest < ActiveSupport::TestCase
  TOKEN = "ab" * 32

  setup do
    @previous = ENV["WATERLEVELS_MCP_TOKEN"]
    ENV["WATERLEVELS_MCP_TOKEN"] = TOKEN
    @called = false
    @gate = Mcp::Gate.new(->(_env) {
      @called = true
      [ 200, { "content-type" => "text/plain" }, [ "ok" ] ]
    })
  end

  teardown do
    restore_token(@previous)
  end

  test "short token returns 404 and does not call the app" do
    ENV["WATERLEVELS_MCP_TOKEN"] = "secret"
    status, headers, = call_gate

    assert_equal 404, status
    assert_private_json(headers)
    assert_not @called
  end

  test "unset token returns 404 and does not call the app" do
    ENV.delete("WATERLEVELS_MCP_TOKEN")
    status, = call_gate(authorization: "Bearer #{TOKEN}")

    assert_equal 404, status
    assert_not @called
  end

  test "missing bearer returns 401" do
    status, headers, body = call_gate

    assert_equal 401, status
    assert_equal "Bearer", headers["www-authenticate"]
    assert_private_json(headers)
    assert_equal [], body
    assert_not @called
  end

  test "wrong bearer returns 401 without echoing the token" do
    status, headers, body = call_gate(authorization: "Bearer not-the-token")

    assert_equal 401, status
    assert_equal "Bearer", headers["www-authenticate"]
    assert_equal [], body
    assert_not @called
  end

  test "authorization longer than 512 bytes returns 401 without hashing" do
    replace_singleton(Digest::SHA256, :hexdigest)
    status, headers, = call_gate(authorization: "Bearer #{"a" * 600}")

    assert_equal 401, status
    assert_equal "Bearer", headers["www-authenticate"]
    assert_not @called
  ensure
    restore_singleton(Digest::SHA256, :hexdigest)
  end

  test "missing content length returns 411 and does not call the app" do
    status, = call_gate(authorization: bearer, content_length: :unset)

    assert_equal 411, status
    assert_not @called
  end

  test "invalid content length returns 411 and does not call the app" do
    status, = call_gate(authorization: bearer, content_length: "nope")

    assert_equal 411, status
    assert_not @called
  end

  test "body over 16KB returns 413 and does not call the app" do
    status, = call_gate(authorization: bearer, content_length: (16 * 1024) + 1)

    assert_equal 413, status
    assert_not @called
  end

  test "non-json content type returns 415" do
    status, = call_gate(authorization: bearer, content_type: "text/plain", content_length: "2")

    assert_equal 415, status
    assert_not @called
  end

  test "valid bearer POST falls through" do
    status, _headers, body = call_gate(authorization: bearer, content_length: "2")

    assert_equal 200, status
    assert_equal [ "ok" ], body
    assert @called
  end

  test "json charset is accepted" do
    status, = call_gate(
      authorization: "bearer #{TOKEN}",
      content_type: "application/json; charset=utf-8",
      content_length: "2"
    )

    assert_equal 200, status
    assert @called
  end

  test "other paths fall through when the token is short" do
    ENV["WATERLEVELS_MCP_TOKEN"] = "secret"
    status, = call_gate(path: "/gauges/wa")

    assert_equal 200, status
    assert @called
  end

  private

  def bearer
    "Bearer #{TOKEN}"
  end

  def call_gate(method: "POST", authorization: nil, content_length: "2", content_type: "application/json", path: "/mcp")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "SCRIPT_NAME" => "",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "example.org",
      "SERVER_PORT" => "80",
      "rack.url_scheme" => "http",
      "rack.input" => UnreadableInput.new,
      "rack.errors" => StringIO.new
    }
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    env["CONTENT_TYPE"] = content_type if content_type
    env["CONTENT_LENGTH"] = content_length.to_s unless content_length == :unset
    @gate.call(env)
  end

  def assert_private_json(headers)
    assert_equal "private, no-store", headers["cache-control"]
    assert_includes headers["content-type"], "application/json"
  end

  def replace_singleton(klass, name)
    singleton = klass.singleton_class
    @replacements ||= []
    backup = :"_mcp_gate_backup_#{name}_#{@replacements.length}"
    singleton.alias_method backup, name
    test_case = self
    singleton.define_method(name) { |*| test_case.flunk("called #{klass}.#{name}") }
    @replacements << [ singleton, name, backup ]
  end

  def restore_singleton(klass, name)
    singleton, method_name, backup = @replacements&.pop
    return unless singleton && method_name == name && klass.singleton_class == singleton

    singleton.alias_method method_name, backup
    singleton.remove_method backup
  end

  def restore_token(previous)
    if previous.nil?
      ENV.delete("WATERLEVELS_MCP_TOKEN")
    else
      ENV["WATERLEVELS_MCP_TOKEN"] = previous
    end
  end

  class UnreadableInput
    def read(*)
      flunk "gate read rack.input"
    end

    def gets(*)
      flunk "gate read rack.input"
    end

    def each(*)
      flunk "gate read rack.input"
    end

    def rewind; end
    def close; end
  end
end
