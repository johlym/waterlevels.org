require "test_helper"

class AppLoggingTest < ActiveSupport::TestCase
  test "enabled? is always true" do
    previous = ENV["LOGRAGE"]
    begin
      ENV["LOGRAGE"] = "0"
      assert AppLogging.enabled?

      ENV.delete("LOGRAGE")
      assert AppLogging.enabled?
    ensure
      if previous.nil?
        ENV.delete("LOGRAGE")
      else
        ENV["LOGRAGE"] = previous
      end
    end
  end

  test "json formats floats hashes and error strings" do
    line = AppLogging.json(
      event: "job.perform",
      duration: 12.3456,
      args: [ "wa", { id: 1 } ],
      error: "RuntimeError: boom boom"
    )
    data = JSON.parse(line)

    assert_equal "job.perform", data["event"]
    assert_equal 12.346, data["duration"]
    assert_equal [ "wa", { "id" => 1 } ], data["args"]
    assert_equal "RuntimeError: boom boom", data["error"]
  end

  test "event defaults level to info" do
    data = JSON.parse(AppLogging.event(event: "sync.progress", job: "DemoJob"))

    assert_equal "info", data["level"]
    assert_equal "sync.progress", data["event"]
  end

  test "extract_logfmt pulls flat fields and status words" do
    fields = AppLogging.extract_logfmt("phase=list_refresh done updated=88 elapsed=24.3s")

    assert_equal "list_refresh", fields[:phase]
    assert_equal "done", fields[:status]
    assert_equal 88, fields[:updated]
    assert_in_delta 24.3, fields[:elapsed]
  end

  test "extract_logfmt keeps inspect-quoted UTF-8 station names" do
    name = "Río Grande at San José"
    fields = AppLogging.extract_logfmt(
      "IvRepairScarJob start id=42 site=08313000 state=nm name=#{name.inspect} " \
      "circuit=history_iv_repair2 key_configured=true"
    )

    assert_equal name, fields[:name]
    assert_equal 42, fields[:id]
    assert_equal 8_313_000, fields[:site]
    assert_equal "nm", fields[:state]
    assert_equal "history_iv_repair2", fields[:circuit]
    assert_equal "true", fields[:key_configured]
  end

  test "extract_logfmt undumps ASCII escaped quotes" do
    fields = AppLogging.extract_logfmt('note="foo \"bar\" baz"')

    assert_equal 'foo "bar" baz', fields[:note]
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

  test "order_fields puts level event message ahead of extras" do
    ordered = AppLogging.order_fields(
      ua: "bot",
      method: "GET",
      status: 200,
      path: "/gauges/wa",
      queries: 3,
      level: "info",
      event: "request",
      message: "GET /gauges/wa 200"
    )

    assert_equal %w[level event message method path status queries ua], ordered.keys
  end

  test "compact tag format merges rid into JSON log lines" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "rid=abc-123" ])

    merged = stack.format_message('{"method":"GET","path":"/"}')
    assert_equal({ "rid" => "abc-123", "method" => "GET", "path" => "/" }, JSON.parse(merged))
  end

  test "compact tag format wraps freeform messages as JSON with message and level" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "rid=abc-123" ])

    wrapped = stack.format_message("hello")
    assert_equal(
      { "rid" => "abc-123", "message" => "hello", "level" => "info" },
      JSON.parse(wrapped)
    )
  end

  test "compact tag format keeps brackets for freeform tags" do
    stack = ActiveSupport::TaggedLogging::TagStack.new
    stack.singleton_class.prepend(AppLogging::CompactTagFormat)
    stack.push_tags([ "ActiveJob", "DemoJob" ])

    assert_equal "[ActiveJob] [DemoJob] hello", stack.format_message("hello")
  end

  test "wrap_unstructured lifts component prefix and logfmt fields" do
    fields = AppLogging.wrap_unstructured(
      "[EdgeCacheInvalidation] purge_tags=0 result=empty",
      severity: "INFO"
    )

    assert_equal "info", fields[:level]
    assert_equal "app.log", fields[:event]
    assert_equal "EdgeCacheInvalidation", fields[:component]
    assert_equal "purge_tags=0 result=empty", fields[:message]
    assert_equal 0, fields[:purge_tags]
    assert_equal "empty", fields[:result]
  end

  test "json formatter wraps unstructured lines and passes JSON through" do
    formatter = AppLogging::JsonFormatter.new

    wrapped = formatter.call("INFO", Time.utc(2026, 8, 12), nil, "[ZipCodeLookup] 98101: boom")
    data = JSON.parse(wrapped)
    assert_equal "info", data["level"]
    assert_equal "ZipCodeLookup", data["component"]
    assert_equal "98101: boom", data["message"]

    json_line = '{"level":"info","event":"request","message":"GET / 200"}'
    passed = formatter.call("INFO", Time.utc(2026, 8, 12), nil, json_line)
    assert_equal "#{json_line}\n", passed
  end

  test "json formatter does not raise on inspect-quoted non-ASCII logfmt" do
    formatter = AppLogging::JsonFormatter.new
    name = "Río Grande at San José"
    line = formatter.call(
      "INFO",
      Time.utc(2026, 9, 21),
      nil,
      "IvRepairScarJob start id=42 site=08313000 name=#{name.inspect}"
    )
    data = JSON.parse(line)

    assert_equal "info", data["level"]
    assert_equal name, data["name"]
    assert_equal 42, data["id"]
  end
end
