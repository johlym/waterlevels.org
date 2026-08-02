require "rails_helper"

RSpec.describe NearbyStations do
  it "returns nearest location ids" do
    origin = [1, 47.0, -122.0]
    near = [2, 47.01, -122.01]
    far = [3, 48.0, -121.0]
    ids = described_class.nearest_ids(1, 47.0, -122.0, [origin, near, far], limit: 1)
    expect(ids).to eq([2])
  end
end
