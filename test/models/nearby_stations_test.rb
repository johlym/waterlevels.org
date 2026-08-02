require "test_helper"

class NearbyStationsTest < ActiveSupport::TestCase
  test "returns nearest location ids" do
    origin = [ 1, 47.0, -122.0 ]
    near = [ 2, 47.01, -122.01 ]
    far = [ 3, 48.0, -121.0 ]
    ids = NearbyStations.nearest_ids(1, 47.0, -122.0, [ origin, near, far ], limit: 1)
    assert_equal [ 2 ], ids
  end
end
