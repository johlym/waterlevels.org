require "test_helper"

class GaugesHelperTest < ActionView::TestCase
  test "related_station_fields reads snapshot keys and fallback measurements" do
    fields = related_station_fields(
      "name" => "Neighbor Creek",
      "path" => "/gauges/wa/example",
      "stale" => false,
      "distance_mi" => 1.25,
      "flood_category" => "minor",
      "primary" => { "kind" => "discharge", "value" => 10 }
    )

    assert_equal "Neighbor Creek", fields[:name]
    assert_equal "/gauges/wa/example", fields[:path]
    assert_equal 1.25, fields[:distance]
    assert_equal "minor", fields[:flood_category]
    assert_equal 1, fields[:readings].size
  end

  test "related_station_watch? is true for NWS alert categories" do
    assert related_station_watch?("action")
    assert related_station_watch?("major")
    refute related_station_watch?("no_flooding")
    refute related_station_watch?(nil)
  end

  test "nearest_stream_neighbor returns the first catalog neighbor" do
    nearest = { site_number: "1" }
    farther = { site_number: "2" }

    assert_equal nearest, nearest_stream_neighbor([ nearest, farther ])
    assert_nil nearest_stream_neighbor([])
  end
end
