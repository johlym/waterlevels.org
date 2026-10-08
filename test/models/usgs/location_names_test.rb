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

      comma_less = "Sacramento River Bl Wilkins Slough Near Grimes CA"
      assert_equal comma_less, LocationNames.format(comma_less)
    end

    test "uppercases a trailing state code with no comma" do
      assert_equal "Sacramento River Bl Wilkins Slough Near Grimes CA",
        LocationNames.format("SACRAMENTO R BL WILKINS SLOUGH NR GRIMES CA")
      assert_equal "Castro Valley C A Hayward CA",
        LocationNames.format("CASTRO VALLEY C A HAYWARD CA")
    end

    test "uppercases a trailing state code after a comma" do
      assert_equal "Colorado River Below Yuma Main Canal Ww At Yuma, AZ",
        LocationNames.format("COLORADO R BLW YUMA MAIN CANAL WW AT YUMA, AZ")
      assert_equal "Potomac River Near Wash, DC",
        LocationNames.format("POTOMAC RIVER NEAR WASH, DC")
    end

    test "leaves mid-name state-shaped words title case" do
      assert_equal "La Crosse River Near La Crosse, WI",
        LocationNames.format("LA CROSSE RIVER NEAR LA CROSSE, WI")
      assert_equal "Nisqually River Near Mt Rainier, WA",
        LocationNames.format("NISQUALLY RIVER NEAR MT RAINIER, WA")
      assert_equal "Jefferson Co, CO",
        LocationNames.format("JEFFERSON CO, CO")
    end

    test "leaves a trailing token that is not a postal code title case" do
      assert_equal "Potomac River At Us",
        LocationNames.format("POTOMAC RIVER AT US")
    end

    test "does not expand abbreviations inside longer words" do
      assert_equal "Blake Creek Near Town, TX",
        LocationNames.format("Blake Ck nr Town, TX")
    end

    test "search_key is lowercase expanded form" do
      assert_equal "lake travis near austin, tx",
        LocationNames.search_key("Lk Travis nr Austin, TX")
    end

    test "drops a USGS period that sits immediately before a comma" do
      assert_equal "Cambridge Reservoir, Unnamed Tributary 3, Near Lexington, MA",
        LocationNames.format("CAMBRIDGE RESERVOIR., UNNAMED TRIBUTARY 3, NEAR LEXINGTON, MA")
    end

    test "blank names stay blank" do
      assert_equal "", LocationNames.format("")
      assert_equal "", LocationNames.format(nil)
    end
  end
end
