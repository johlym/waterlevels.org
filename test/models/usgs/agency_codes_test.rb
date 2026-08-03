require "test_helper"

module Usgs
  class AgencyCodesTest < ActiveSupport::TestCase
    test "usgs? is case-insensitive" do
      assert AgencyCodes.usgs?("USGS")
      assert AgencyCodes.usgs?("usgs")
      assert_not AgencyCodes.usgs?("TX071")
      assert_not AgencyCodes.usgs?(nil)
    end

    test "credit_for returns nil for USGS" do
      assert_nil AgencyCodes.credit_for("USGS", agency_name: "U.S. Geological Survey")
    end

    test "credit_for cleans trailing state abbreviations" do
      assert_equal "Lower Colorado River Authority",
        AgencyCodes.credit_for("TX071", agency_name: "Lower Colorado River Authority, TX")
    end

    test "credit_for keeps names without a state suffix" do
      assert_equal "Texas Commission on Environmental Quality",
        AgencyCodes.credit_for("TX003", agency_name: "Texas Commission on Environmental Quality")
    end

    test "credit_for returns nil when non-USGS name is blank" do
      assert_nil AgencyCodes.credit_for("TX071", agency_name: nil)
      assert_nil AgencyCodes.credit_for("TX071", agency_name: "  ")
    end
  end
end
