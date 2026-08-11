require "test_helper"

class AppLoggingTest < ActiveSupport::TestCase
  test "key_value formats floats hashes and error strings" do
    line = AppLogging.key_value(
      event: "job.perform",
      duration: 12.3456,
      args: [ "wa", { id: 1 } ],
      error: "RuntimeError: boom boom"
    )

    assert_includes line, "event=job.perform"
    assert_includes line, "duration=12.35"
    assert_includes line, 'args=["wa",{"id":1}]'
    assert_includes line, 'error="RuntimeError: boom boom"'
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

    assert_equal %i[method path status queries ua], ordered.keys
  end

  test "compact tag format joins key=value tags without brackets" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "rid=abc-123" ])

    assert_equal "rid=abc-123 method=GET path=/", stack.format_message("method=GET path=/")
  end

  test "compact tag format keeps brackets for freeform tags" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "ActiveJob", "DemoJob" ])

    assert_equal "[ActiveJob] [DemoJob] hello", stack.format_message("hello")
  end
end
