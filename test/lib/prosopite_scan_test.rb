require "test_helper"

class ProsopiteScanTest < ActiveSupport::TestCase
  test "reports repeated queries from the same call site" do
    locations = create_list(:monitoring_location, 3)

    assert_n_plus_one_queries do
      locations.each { |location| location.time_series.load }
    end
  end

  test "a preloaded association is not an n+1" do
    locations = create_list(:monitoring_location, 3)
    locations.each { |location| create(:time_series, monitoring_location: location) }

    assert_no_n_plus_one_queries do
      MonitoringLocation.where(id: locations.map(&:id)).includes(:time_series).each do |location|
        location.time_series.map(&:id)
      end
    end
  end
end
