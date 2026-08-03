require "test_helper"

class AlertsListingCacheTest < ActiveSupport::TestCase
  test "warm builds payload of flood-alert stations ordered by state then severity" do
    create(
      :monitoring_location,
      site_number: "400",
      usgs_monitoring_location_id: "USGS-400",
      name: "ACTION CREEK, WA",
      state_code: "wa",
      state_name: "Washington",
      flood_category: "action"
    )
    create(
      :monitoring_location,
      site_number: "401",
      usgs_monitoring_location_id: "USGS-401",
      name: "MAJOR RIVER, TX",
      state_code: "tx",
      state_name: "Texas",
      flood_category: "major"
    )
    create(
      :monitoring_location,
      site_number: "402",
      usgs_monitoring_location_id: "USGS-402",
      name: "MINOR CREEK, TX",
      state_code: "tx",
      state_name: "Texas",
      flood_category: "minor"
    )
    create(
      :monitoring_location,
      site_number: "403",
      usgs_monitoring_location_id: "USGS-403",
      name: "QUIET CREEK, WA",
      state_code: "wa",
      flood_category: "no_flooding"
    )

    payload = AlertsListingCache.warm

    assert_equal 3, payload[:total_count]
    assert_equal 2, payload[:state_count]
    assert_equal 1, payload[:major_count]
    assert_equal %w[401 402 400], payload[:locations].map { |row| row[:site_number] }
    assert payload[:locations].all? { |row| row[:flood_alert] }
    assert_equal "Texas", payload[:locations].first[:state_name]
  end

  test "fetch warms on cache miss" do
    create(
      :monitoring_location,
      site_number: "404",
      usgs_monitoring_location_id: "USGS-404",
      name: "FLOOD CREEK, WA",
      state_code: "wa",
      flood_category: "moderate"
    )

    Rails.cache.clear
    payload = AlertsListingCache.fetch

    assert_equal 1, payload[:total_count]
    assert_equal "404", payload[:locations].first[:site_number]
  end
end
