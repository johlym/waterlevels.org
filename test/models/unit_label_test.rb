require "test_helper"

class UnitLabelTest < ActiveSupport::TestCase
  test "formats cubic feet abbreviations with a superscript three" do
    assert_equal "ft³/s", UnitLabel.format("ft3/s")
    assert_equal "ft³/s", UnitLabel.format("ft^3/s")
    assert_equal "ft³/s", UnitLabel.format("ft³/s")
    assert_equal "ft³/sec", UnitLabel.format("FT3/sec")
  end

  test "leaves unrelated units alone" do
    assert_equal "ft", UnitLabel.format("ft")
    assert_nil UnitLabel.format(nil)
  end
end
