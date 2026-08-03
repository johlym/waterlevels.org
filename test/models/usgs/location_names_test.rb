require "test_helper"

module Usgs
  class LocationNamesTest < ActiveSupport::TestCase
    test "expands lake and near abbreviations and titlecases" do
      assert_equal "Lake Travis Near Austin, TX",
        LocationNames.format("LK TRAVIS NR AUSTIN, TX")
      assert_equal "Lake Travis Near Austin, TX",
        LocationNames.format("Lk Travis nr Austin, tx")
    end

    test "expands river and creek abbreviations" do
      assert_equal "Nueces River Near Three Rivers, TX",
        LocationNames.format("Nueces Rv nr Three Rivers, TX")
      assert_equal "Onion Creek At Highway 183, TX",
        LocationNames.format("Onion Ck at Hwy 183, TX")
      assert_equal "Colorado River Near Columbus, TX",
        LocationNames.format("Colorado R nr Columbus, TX")
    end

    test "titlecases all-caps full-word USGS names" do
      assert_equal "Lake Tapps Near Sumner, WA",
        LocationNames.format("LAKE TAPPS NEAR SUMNER, WA")
      assert_equal "Potomac River Near Wash, DC",
        LocationNames.format("POTOMAC RIVER NEAR WASH, DC")
    end

    test "is idempotent for already-formatted names" do
      formatted = "Lake Travis Near Austin, TX"
      assert_equal formatted, LocationNames.format(formatted)
    end

    test "does not expand abbreviations inside longer words" do
      assert_equal "Blake Creek Near Town, TX",
        LocationNames.format("Blake Ck nr Town, TX")
    end

    test "search_key is lowercase expanded form" do
      assert_equal "lake travis near austin, tx",
        LocationNames.search_key("Lk Travis nr Austin, TX")
    end

    test "blank names stay blank" do
      assert_equal "", LocationNames.format("")
      assert_equal "", LocationNames.format(nil)
    end
  end
end
