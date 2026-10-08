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

  test "related_station_stale? reads boolean or string flags" do
    assert related_station_stale?({ stale: true })
    assert related_station_stale?("stale" => "true")
    refute related_station_stale?({ stale: false })
    refute related_station_stale?({ name: "Live Creek" })
  end

  test "related_map_payload orders the stream and keeps a shared station upstream" do
    payload = related_map_payload(
      upstream: [
        map_station("00000002", "Near Upstream", 47.51, -121.80),
        map_station("00000003", "Far Upstream", 47.60, -121.70)
      ],
      downstream: [
        map_station("00000004", "Near Downstream", 47.40, -121.90)
      ],
      nearby: [
        map_station("00000002", "Near Upstream", 47.51, -121.80),
        map_station("00000005", "Side Creek", 47.46, -121.70, distance_mi: 3.2)
      ],
      current: {
        site_number: "00000001",
        name: "Origin Creek",
        latitude: 47.45,
        longitude: -121.85
      }
    )

    assert_equal "00000001", payload[:current][:site_number]
    assert_in_delta 47.45, payload[:current][:lat], 0.0001
    assert_in_delta(-121.85, payload[:current][:lon], 0.0001)
    assert_equal %w[00000003 00000002 00000004 00000005], payload[:stations].map { |station| station[:site_number] }
    assert_equal %w[upstream upstream downstream nearby], payload[:stations].map { |station| station[:role] }
    assert_in_delta 3.2, payload[:stations].last[:distance_mi], 0.001
  end

  test "related_map_payload skips stations without coordinates" do
    payload = related_map_payload(
      upstream: [],
      downstream: [],
      nearby: [
        { "site_number" => "00000008", "name" => "Missing Coordinates" },
        map_station("00000009", "Has Coordinates", 47.2, -121.2)
      ],
      current: { site_number: "00000001", name: "Origin", latitude: 47.0, longitude: -121.0 }
    )

    assert_equal [ "00000009" ], payload[:stations].map { |station| station[:site_number] }
    assert_equal "nearby", payload[:stations].first[:role]
  end

  test "related_station_watch? is true for NWS alert categories" do
    assert related_station_watch?("action")
    assert related_station_watch?("major")
    refute related_station_watch?("no_flooding")
    refute related_station_watch?(nil)
  end

  private

  def map_station(site_number, name, latitude, longitude, distance_mi: nil)
    {
      site_number: site_number,
      name: name,
      latitude: latitude,
      longitude: longitude,
      path: "/gauges/wa/#{site_number}-example",
      distance_mi: distance_mi,
      flood_category: "no_flooding"
    }
  end
end
