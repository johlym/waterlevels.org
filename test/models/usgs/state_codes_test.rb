require "test_helper"

module Usgs
  class StateCodesTest < ActiveSupport::TestCase
    test "normalizes postal and FIPS codes" do
      assert_equal "wa", StateCodes.normalize_postal("WA")
      assert_equal "wa", StateCodes.normalize_postal("53")
      assert_equal "53", StateCodes.fips_for("wa")
      assert_equal "Washington", StateCodes.name_for("wa")
    end

    test "rejects unknown states" do
      assert_raises(ArgumentError) { StateCodes.normalize_postal("zz") }
    end
  end
end
