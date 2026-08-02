require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "titlecases USGS location names and keeps state abbreviation" do
    assert_equal "Lake Tapps Near Sumner, WA", display_location_name("LAKE TAPPS NEAR SUMNER, WA")
  end

  test "formats timestamps as Month Day, Year at HH:MM:SS AM/PM" do
    time = Time.utc(2026, 8, 2, 4, 30, 0)
    assert_equal "August 2, 2026 at 04:30:00 AM", display_timestamp(time)
  end
end
