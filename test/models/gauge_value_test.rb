require "test_helper"

class GaugeValueTest < ActiveSupport::TestCase
  test "pads fractional gauge values to two decimal places" do
    assert_equal "541.10", GaugeValue.format(541.1)
    assert_equal "541.10", GaugeValue.format("541.1")
    assert_equal "8.25", GaugeValue.format(8.25)
  end

  test "omits decimals for whole-number gauge values" do
    assert_equal "540", GaugeValue.format(540)
    assert_equal "540", GaugeValue.format(540.0)
    assert_equal "540", GaugeValue.format("540.00")
  end

  test "respects precision zero for discharge-style values" do
    assert_equal "1,240", GaugeValue.format(1240.4, precision: 0)
    assert_equal "12", GaugeValue.format(12.0, precision: 0)
  end

  test "adds thousands delimiters" do
    assert_equal "1,234.50", GaugeValue.format(1234.5)
    assert_equal "1,234", GaugeValue.format(1234)
  end

  test "returns nil for blank values" do
    assert_nil GaugeValue.format(nil)
  end
end
