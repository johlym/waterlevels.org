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
end
