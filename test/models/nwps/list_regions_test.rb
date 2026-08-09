require "test_helper"

module Nwps
  class ListRegionsTest < ActiveSupport::TestCase
    test "defines exactly ten list regions" do
      assert_equal 10, ListRegions.ids.size
    end

    test "every catalog state is covered by at least one region" do
      covered = ListRegions::REGIONS.values.flat_map { |meta| meta.fetch(:states) }.uniq.sort
      assert_equal Usgs::StateCodes::STATES.keys.sort, covered
    end

    test "each region has a valid WGS84 bbox" do
      ListRegions.ids.each do |region_id|
        bbox = ListRegions.bbox_for(region_id)
        %i[xmin ymin xmax ymax].each { |key| assert bbox.key?(key), "#{region_id} missing #{key}" }
        assert_operator bbox.fetch(:xmin), :<, bbox.fetch(:xmax), region_id
        assert_operator bbox.fetch(:ymin), :<, bbox.fetch(:ymax), region_id
      end
    end

    test "ids_covering_state returns pacific for Washington" do
      assert_equal [ "conus_pacific" ], ListRegions.ids_covering_state("wa")
    end

    test "ids_covering_state can return multiple bands for border states" do
      ids = ListRegions.ids_covering_state("tx")
      assert_includes ids, "conus_rockies_high_plains"
      assert_includes ids, "conus_central"
    end
  end
end
