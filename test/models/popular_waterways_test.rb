require "test_helper"

class PopularWaterwaysTest < ActiveSupport::TestCase
  test "regions only include stations present in the database" do
    create(
      :monitoring_location,
      site_number: "07010000",
      usgs_monitoring_location_id: "USGS-07010000",
      name: "MISSISSIPPI RIVER AT ST. LOUIS, MO",
      state_code: "mo",
      state_name: "Missouri"
    )

    regions = PopularWaterways.regions
    mississippi = regions.find { |region| region.key == "mississippi-basin" }

    assert_equal "Mississippi Basin", mississippi.name
    assert_equal [ "07010000" ], mississippi.stations.map(&:site_number)
    assert regions.find { |region| region.key == "colorado-river" }.stations.empty?
  end
end
