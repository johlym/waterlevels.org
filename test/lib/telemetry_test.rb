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
end
