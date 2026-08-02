require "test_helper"

class MonitoringLocationTest < ActiveSupport::TestCase
  test "requires site_number and name" do
    location = MonitoringLocation.new
    assert_not location.valid?
    assert_includes location.errors.attribute_names, :site_number
    assert_includes location.errors.attribute_names, :name
  end

  test "is stale when observation is older than one week" do
    location = build(:monitoring_location, latest_observed_at: 8.days.ago)
    assert location.stale?
  end

  test "is not stale when recently observed" do
    location = build(:monitoring_location, latest_observed_at: 1.hour.ago)
    assert_not location.stale?
  end

  test "ordered_for_state_table sorts by county then name" do
    b = create(:monitoring_location, site_number: "1", usgs_monitoring_location_id: "USGS-1", county_name: "Benton", name: "Zebra")
    a = create(:monitoring_location, site_number: "2", usgs_monitoring_location_id: "USGS-2", county_name: "Adams", name: "Alpha")
    c = create(:monitoring_location, site_number: "3", usgs_monitoring_location_id: "USGS-3", county_name: "Adams", name: "Beta")

    assert_equal [ a, c, b ], MonitoringLocation.ordered_for_state_table
  end
end
