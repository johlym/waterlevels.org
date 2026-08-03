require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "titlecases USGS location names and keeps state abbreviation" do
    assert_equal "Lake Tapps Near Sumner, WA", display_location_name("LAKE TAPPS NEAR SUMNER, WA")
  end

  test "expands USGS location abbreviations for display" do
    assert_equal "Lake Travis Near Austin, TX", display_location_name("Lk Travis nr Austin, TX")
    assert_equal "Nueces River Near Three Rivers, TX", display_location_name("Nueces Rv nr Three Rivers, TX")
  end

  test "strips trailing County from county names" do
    assert_equal "King", display_county_name("King County")
    assert_equal "King", display_county_name("King")
    assert_equal "St. Louis", display_county_name("St. Louis County")
  end

  test "formats timestamps as Month Day, Year at HH:MM:SS AM/PM" do
    time = Time.utc(2026, 8, 2, 4, 30, 0)
    assert_equal "August 2, 2026 at 04:30:00 AM UTC", display_timestamp(time)
  end

  test "formats timestamps in the station local time zone" do
    time = Time.utc(2026, 8, 2, 4, 30, 0)
    assert_equal "August 1, 2026 at 11:30:00 PM CDT", display_timestamp(time, time_zone: "CST")
    assert_equal "August 1, 2026 at 09:30:00 PM PDT", display_timestamp(time, time_zone: "America/Los_Angeles")
  end

  test "maps Arizona MST without daylight saving" do
    time = Time.utc(2026, 8, 2, 4, 30, 0)
    assert_equal "August 1, 2026 at 09:30:00 PM MST",
      display_timestamp(time, time_zone: "MST", state_code: "az")
  end
end
