require "test_helper"

class NearbyStationsTest < ActiveSupport::TestCase
  test "returns nearest location ids" do
    origin = [ 1, 47.0, -122.0 ]
    near = [ 2, 47.01, -122.01 ]
    far = [ 3, 48.0, -121.0 ]
    ids = NearbyStations.nearest_ids(1, 47.0, -122.0, [ origin, near, far ], limit: 1)
    assert_equal [ 2 ], ids
  end

  test "refresh_all uses nearby grid candidates" do
    origin = create(:monitoring_location, site_number: "10000001", latitude: 47.0, longitude: -122.0)
    near = create(:monitoring_location, site_number: "10000002", latitude: 47.01, longitude: -122.01)
    far = create(:monitoring_location, site_number: "10000003", latitude: 48.5, longitude: -121.0)

    NearbyStations.refresh_all

    origin.reload
    assert_includes origin.nearby_station_ids, near.id
    refute_includes origin.nearby_station_ids.first(1), far.id
  end

  test "nearest_to returns the closest monitoring location" do
    create(:monitoring_location, site_number: "10000011", latitude: 47.0, longitude: -122.0)
    near = create(:monitoring_location, site_number: "10000012", latitude: 47.02, longitude: -122.02)
    create(:monitoring_location, site_number: "10000013", latitude: 48.5, longitude: -121.0)

    assert_equal near, NearbyStations.nearest_to(47.021, -122.021)
  end
end

