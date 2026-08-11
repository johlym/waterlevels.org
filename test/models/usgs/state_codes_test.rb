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
      assert_raises(ArgumentError) { StateCodes.normalize_postal("95") }
    end

    test "try_normalize_postal soft-fails for Canadian and unknown FIPS" do
      assert_equal "wa", StateCodes.try_normalize_postal("53")
      assert_nil StateCodes.try_normalize_postal("95")
      assert_nil StateCodes.try_normalize_postal("zz")
      assert_nil StateCodes.try_normalize_postal("")
      assert_equal false, StateCodes.known?("95")
      assert_equal true, StateCodes.known?("wa")
    end

    test "match_query finds states by name, prefix, and postal code" do
      assert_equal [ { postal: "tx", name: "Texas" } ], StateCodes.match_query("Texas")
      assert_equal [ { postal: "tx", name: "Texas" } ], StateCodes.match_query("tex")
      assert_equal [ { postal: "tx", name: "Texas" } ], StateCodes.match_query("TX")
      assert_equal [], StateCodes.match_query("t")
      assert_equal [], StateCodes.match_query("xyz")

      names = StateCodes.match_query("New").map { |match| match[:name] }
      assert_includes names, "New York"
      assert_includes names, "New Jersey"
      assert_includes names, "New Hampshire"
      assert_equal "New York", names.first
    end

    test "bbox_for returns a valid padded WGS84 envelope per state" do
      StateCodes::STATES.each_key do |postal|
        bbox = StateCodes.bbox_for(postal)
        %i[xmin ymin xmax ymax].each { |key| assert bbox.key?(key), "#{postal} missing #{key}" }
        assert_operator bbox.fetch(:xmin), :<, bbox.fetch(:xmax), postal
        assert_operator bbox.fetch(:ymin), :<, bbox.fetch(:ymax), postal
      end
    end
  end
end
