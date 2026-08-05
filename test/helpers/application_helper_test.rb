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

  test "formats gauge values with two decimal places when fractional" do
    assert_equal "541.10", display_gauge_value(541.1)
    assert_equal "540", display_gauge_value(540)
    assert_equal "+1.50", signed_number(1.5, precision: 2)
    assert_equal "-2", signed_number(-2, precision: 2)
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

  test "annotates glossary terms with CSS tooltip markup" do
    html = annotate_glossary_terms("Height above datum")
    assert_includes html, 'class="term-tip"'
    assert_includes html, 'class="term-tip-bubble"'
    assert_includes html, 'role="tooltip"'
    assert_includes html, "Height above "
    assert_includes html, ">datum<span"
    assert_includes html, "reference surface"
    assert_includes html, 'tabindex="0"'

    navd = annotate_glossary_terms("Elevation (NAVD 1988)")
    assert_includes navd, ">NAVD 1988<span"
    assert_includes navd, "North American Vertical Datum of 1988"

    ngvd = annotate_glossary_terms("Elevation (NGVD 1929)")
    assert_includes ngvd, ">NGVD 1929<span"
    assert_includes ngvd, "National Geodetic Vertical Datum of 1929"

    provisional = annotate_glossary_terms("Provisional")
    assert_includes provisional, ">Provisional<span"
    assert_includes provisional, "not finished review"
  end

  test "glossary tooltips escape surrounding text and can omit tabindex" do
    html = annotate_glossary_terms("Height above datum <script>", focusable: false)
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "tabindex"
    assert_includes html, 'class="term-tip"'
  end
end
