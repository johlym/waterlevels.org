require "test_helper"

module Usgs
  class SiteTypesTest < ActiveSupport::TestCase
    test "allows surface-water site types and rejects groundwater" do
      assert SiteTypes.water_body?("ST")
      assert SiteTypes.water_body?("lk")
      assert_not SiteTypes.water_body?("GW")
      assert_not SiteTypes.water_body?("GW-MW")
    end
  end
end
