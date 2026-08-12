require "test_helper"

class AppLoggingTest < ActiveSupport::TestCase
  test "json formats floats hashes and error strings" do
    line = AppLogging.json(
      event: "job.perform",
      duration: 12.3456,
      args: [ "wa", { id: 1 } ],
      error: "RuntimeError: boom boom"
    )
    data = JSON.parse(line)

    assert_equal "job.perform", data["event"]
    assert_equal 12.35, data["duration"]
    assert_equal [ "wa", { "id" => 1 } ], data["args"]
    assert_equal "RuntimeError: boom boom", data["error"]
  end

  test "json omits nil values" do
    line = AppLogging.json(event: "job.perform", error: nil, status: "ok")
    data = JSON.parse(line)

    assert_equal({ "event" => "job.perform", "status" => "ok" }, data)
  end

  test "filtered_params drops controller action and filterable secrets" do
    params = {
      "controller" => "gauges",
      "action" => "show",
      "state" => "wa",
      "password" => "secret",
      "token" => "abc"
    }

    filtered = AppLogging.filtered_params(params)

    assert_equal "wa", filtered["state"]
    assert_nil filtered["controller"]
    assert_nil filtered["action"]
    assert_equal "[FILTERED]", filtered["password"]
    assert_equal "[FILTERED]", filtered["token"]
  end

  test "truncate_ua shortens long user agents" do
    ua = "Mozilla/5.0 #{'x' * 200}"
    truncated = AppLogging.truncate_ua(ua)

    assert_operator truncated.length, :<=, AppLogging::USER_AGENT_MAX
    assert_match(/…\z/, truncated)
  end

  test "order_fields puts method path status ahead of extras" do
    ordered = AppLogging.order_fields(
      ua: "bot",
      method: "GET",
      status: 200,
      path: "/gauges/wa",
      queries: 3
    )

    assert_equal %w[method path status queries ua], ordered.keys
  end

  test "compact tag format merges rid into JSON log lines" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "rid=abc-123" ])

    merged = stack.format_message('{"method":"GET","path":"/"}')
    assert_equal({ "rid" => "abc-123", "method" => "GET", "path" => "/" }, JSON.parse(merged))
  end

  test "compact tag format wraps freeform messages as JSON with rid" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "rid=abc-123" ])

    wrapped = stack.format_message("hello")
    assert_equal({ "rid" => "abc-123", "msg" => "hello" }, JSON.parse(wrapped))
  end

  test "compact tag format keeps brackets for freeform tags" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "ActiveJob", "DemoJob" ])

    assert_equal "[ActiveJob] [DemoJob] hello", stack.format_message("hello")
  end
end
