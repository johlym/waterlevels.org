require "test_helper"

class SeoTest < ActiveSupport::TestCase
  CAMBRIDGE = "Cambridge Reservoir, Unnamed Tributary 3, Near Lexington, MA"

  test "gauge title keeps the waterbody and drops the locality when the full name will not fit" do
    title = Seo.gauge_title(name: CAMBRIDGE, state_code: "ma", kinds: %w[water_level discharge temperature])

    assert_equal "Cambridge Reservoir, Unnamed Tributary 3 Water Level | MA", title
    assert_operator title.length, :<=, Seo::GAUGE_TITLE_LIMIT
    assert_not_includes title, "Tribute"
    assert_not_includes title, "WaterLevels.org"
  end

  test "short gauge names keep flow in the title when it still fits" do
    title = Seo.gauge_title(
      name: "Example River Near Town",
      state_code: "wa",
      kinds: %w[water_level discharge]
    )

    assert_equal "Example River Near Town Water Level & Flow | WA", title
    assert_operator title.length, :<=, Seo::GAUGE_TITLE_LIMIT
  end

  test "level-only stations do not claim flow in the title" do
    title = Seo.gauge_title(name: "Example River Near Town", state_code: "wa", kinds: %w[water_level])

    assert_equal "Example River Near Town Water Level | WA", title
  end

  test "flow-only stations lead with streamflow" do
    title = Seo.gauge_title(name: "Example River Near Town", state_code: "wa", kinds: %w[discharge])

    assert_equal "Example River Near Town Streamflow | WA", title
  end

  test "very long names are cut on a word boundary" do
    name = "Superlong Unnamed Tributary To The Something River Number Twelve Bypass"
    title = Seo.gauge_title(name: name, state_code: "ma", kinds: %w[water_level])

    assert_operator title.length, :<=, Seo::GAUGE_TITLE_LIMIT
    assert title.end_with?(" Water Level | MA")
    assert_not_includes title, "Tribute"
    place = title.delete_suffix(" Water Level | MA")
    assert_includes name, place
  end

  test "gauge description mentions only the measurements the station has and stays within the snippet limit" do
    description = Seo.gauge_description(
      name: CAMBRIDGE,
      agency: "U.S. Geological Survey",
      county_name: "Middlesex",
      state_name: "Massachusetts",
      kinds: %w[water_level discharge temperature]
    )

    assert_operator description.length, :<=, Seo::DESCRIPTION_LIMIT
    assert_includes description, "water level, flow, and temperature"
    assert_includes description, "Cambridge Reservoir, Unnamed Tributary 3, Near Lexington, MA"
    assert_includes description, "U.S. Geological Survey"
  end

  test "breadcrumb list numbers visible ancestors and the current page" do
    data = Seo.breadcrumb_list([
      [ "Map", "https://waterlevels.org/" ],
      [ "Massachusetts", "https://waterlevels.org/gauges/ma" ],
      [ "Middlesex", "https://waterlevels.org/gauges/ma#middlesex" ],
      [ "Cambridge Reservoir, Unnamed Tributary 3, Near Lexington, MA", "https://waterlevels.org/gauges/ma/01104420-cambridge" ]
    ])

    assert_equal "BreadcrumbList", data["@type"]
    assert_equal [ 1, 2, 3, 4 ], data["itemListElement"].map { |item| item["position"] }
    assert_equal "Massachusetts", data["itemListElement"][1]["name"]
    assert_equal "https://waterlevels.org/gauges/ma", data["itemListElement"][1]["item"]
  end
end
