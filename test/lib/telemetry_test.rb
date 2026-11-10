require "test_helper"

class TelemetryTest < ActiveSupport::TestCase
  test "in_span yields and returns the block value" do
    result = Telemetry.in_span("test.operation", attributes: { "app.example" => true }) do
      Telemetry.add_attributes("app.step" => "done")
      42
    end

    assert_equal 42, result
  end

  test "in_span re-raises errors after marking the span" do
    error = assert_raises(RuntimeError) do
      Telemetry.in_span("test.failing") do
        raise "boom"
      end
    end

    assert_equal "boom", error.message
  end

  test "in_root_span creates an independent root and returns the block value" do
    nested_parent_id = nil
    root_parent_id = :unset

    Telemetry.in_span("test.ambient_parent") do |parent|
      nested_parent_id = parent.context.hex_span_id

      result = Telemetry.in_root_span(
        "test.root_operation",
        attributes: {
          "app.operation" => "test.root_operation",
          "app.batch_size" => 3,
          "app.observation_count" => 10,
          "app.site_number" => "99000099"
        }
      ) do |root|
        root_parent_id = root.parent_span_id
        Telemetry.add_attributes("app.state" => "wa")
        "ok"
      end

      assert_equal "ok", result
    end

    assert nested_parent_id.present?
    # Root spans have an invalid/empty parent span id (not the ambient parent).
    assert_not_equal nested_parent_id, root_parent_id
  end

  test "work span records lane, skip outcome, and accumulated http time" do
    Telemetry.work("history_backfill", provider: "usgs") do |span|
      Telemetry.skip!("disabled_by_settings")
      Telemetry.record_http(12)
      Telemetry.record_http(8)
      Telemetry.phase("continuous") { nil }

      attrs = span.attributes
      assert_equal "pipeline.work", span.name
      assert_equal "work", attrs["pipeline.signal"]
      assert_equal "history_backfill", attrs["pipeline.lane"]
      assert_equal "usgs", attrs["pipeline.provider"]
      assert_equal "skipped", attrs["pipeline.outcome"]
      assert_equal "disabled_by_settings", attrs["pipeline.skip_reason"]
      assert_equal 20, attrs["pipeline.http_ms"]
      assert_equal 2, attrs["pipeline.http_count"]
      assert_kind_of Integer, attrs["pipeline.phase.continuous_ms"]
    end
  end

  test "work span marks exceptions as errors" do
    span = nil
    error = assert_raises(RuntimeError) do
      Telemetry.work("iv_repair") do |current|
        span = current
        raise "boom"
      end
    end

    assert_equal "boom", error.message
    assert_equal "error", span.attributes["pipeline.outcome"]
    assert_equal true, span.attributes["error"]
  end

  test "ensure_work adds attributes to the current work span" do
    Telemetry.work("iv_repair", provider: "usgs") do |outer|
      outer_id = outer.context.hex_span_id
      Telemetry.ensure_work("history_backfill", site_number: "99000001", incomplete: true) do |current|
        assert_equal outer_id, current.context.hex_span_id
        Telemetry.record_http(4)
      end

      assert_equal "iv_repair", outer.attributes["pipeline.lane"]
      assert_equal "99000001", outer.attributes["pipeline.site_number"]
      assert_equal true, outer.attributes["pipeline.incomplete"]
      assert_equal 4, outer.attributes["pipeline.http_ms"]
      assert_equal 1, outer.attributes["pipeline.http_count"]
    end
  end

  test "gauge is an unlinked root" do
    queue = nil
    Telemetry.work("latest_sync") do |work|
      queue = Telemetry.gauge(
        "pipeline.queue",
        signal: "queue",
        queue: "backfill",
        "queue.depth": 0,
        "queue.latency_s": 0.0
      )
      assert_not_equal work.context.hex_span_id, queue.context.hex_span_id
    end

    assert_equal "pipeline.queue", queue.name
    assert_equal "queue", queue.attributes["pipeline.signal"]
    assert_equal "backfill", queue.attributes["pipeline.queue"]
    assert_equal 0, queue.attributes["pipeline.queue.depth"]
    assert_empty Array(queue.links)
  end

  test "record_http outside a span does not raise" do
    assert_nothing_raised { Telemetry.record_http(5) }
  end
end
