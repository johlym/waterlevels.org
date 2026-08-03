require "test_helper"

module Nwps
  class FloodCategoriesTest < ActiveSupport::TestCase
    test "normalizes known categories" do
      assert_equal "minor", FloodCategories.normalize("Minor")
      assert_equal "no_flooding", FloodCategories.normalize("no_flooding")
      assert_nil FloodCategories.normalize("unknown")
      assert_nil FloodCategories.normalize(nil)
    end

    test "alert? is true for action and flood tiers" do
      assert FloodCategories.alert?("action")
      assert FloodCategories.alert?("major")
      assert_not FloodCategories.alert?("no_flooding")
      assert_not FloodCategories.alert?(nil)
    end

    test "stage_value drops NWPS sentinels" do
      assert_in_delta 10.0, FloodCategories.stage_value(10), 0.001
      assert_nil FloodCategories.stage_value(-9999)
      assert_nil FloodCategories.stage_value(0)
      assert_nil FloodCategories.stage_value(nil)
    end

    test "effective picks the more severe of observed and forecast" do
      assert_equal "major", FloodCategories.effective("minor", "major")
      assert_equal "action", FloodCategories.effective("action", "no_flooding")
      assert_equal "moderate", FloodCategories.effective("obs_not_current", "moderate")
      assert_nil FloodCategories.effective("obs_not_current", "fcst_not_current")
    end
  end
end
