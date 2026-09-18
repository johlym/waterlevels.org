require "test_helper"

class DataProvidersTest < ActiveSupport::TestCase
  test "agency_url_for usgs uses waterdata monitoring-location path" do
    location = build(:monitoring_location,
      data_provider: DataProviders::USGS,
      provider_location_id: "USGS-01646500")

    assert_equal(
      "https://waterdata.usgs.gov/monitoring-location/USGS-01646500/",
      DataProviders.agency_url_for(location)
    )
    assert_equal "U.S. Geological Survey", location.agency_label
    assert location.usgs?
  end

  test "agency_url_for nwps uses water.noaa.gov gauge path" do
    location = build(:monitoring_location,
      data_provider: DataProviders::NWPS,
      provider_location_id: "NWPS-ACRW1",
      site_number: "nwpsacrw1",
      nwps_lid: "ACRW1")

    assert_equal "https://water.noaa.gov/gauges/ACRW1", DataProviders.agency_url_for(location)
    assert_equal "National Weather Service", location.agency_label
    assert_not location.usgs?
  end

  test "agency_url_for usace uses CWMS location path" do
    location = build(:monitoring_location,
      data_provider: DataProviders::USACE,
      provider_location_id: "USACE-NAB-Raystown",
      site_number: "usacenabraystown")

    assert_equal(
      "https://cwms-data.usace.army.mil/cwms-data/locations/Raystown?office=NAB",
      DataProviders.agency_url_for(location)
    )
    assert_equal "U.S. Army Corps of Engineers", location.agency_label
    assert_not location.usgs?
  end

  test "agency_url_for usbr uses RISE location page" do
    location = build(:monitoring_location,
      data_provider: DataProviders::USBR,
      provider_location_id: "USBR-3514",
      site_number: "usbr3514")

    assert_equal "https://data.usbr.gov/location/3514", DataProviders.agency_url_for(location)
    assert_equal "U.S. Bureau of Reclamation", location.agency_label
    assert_not location.usgs?
  end

  test "daily_only? is true for non-usgs stations without continuous tips" do
    location = create(:monitoring_location,
      data_provider: DataProviders::USBR,
      provider_location_id: "USBR-3514",
      site_number: "usbr3514")
    create(:time_series,
      monitoring_location: location,
      has_continuous_anchor: false,
      continuous_newest_at: nil)

    assert location.daily_only?
    assert_equal "1y", location.default_chart_range
    assert_equal %w[30d 1y], location.chart_ranges
  end

  test "daily_only? is false for usgs even without continuous denorm tips" do
    location = create(:monitoring_location)
    create(:time_series,
      monitoring_location: location,
      has_continuous_anchor: false,
      continuous_newest_at: nil)

    assert_not location.daily_only?
    assert_equal "7d", location.default_chart_range
    assert_includes location.chart_ranges, "24h"
  end

  test "daily_only? is false when a non-usgs selected series has continuous tip" do
    location = create(:monitoring_location,
      data_provider: DataProviders::USACE,
      provider_location_id: "USACE-MVP-TEST",
      site_number: "usaceMVPTEST")
    create(:time_series,
      monitoring_location: location,
      has_continuous_anchor: true,
      continuous_newest_at: 1.hour.ago)

    assert_not location.daily_only?
    assert_equal "7d", location.default_chart_range
    assert_includes location.chart_ranges, "24h"
  end

  test "iv repair candidates exclude non-usgs locations" do
    usgs = create(:monitoring_location, data_provider: DataProviders::USGS)
    usbr = create(:monitoring_location,
      data_provider: DataProviders::USBR,
      provider_location_id: "USBR-3514",
      site_number: "usbr3514")

    create(:time_series,
      monitoring_location: usgs,
      selected_for_display: true,
      has_continuous_anchor: true,
      continuous_newest_at: 3.days.ago)
    create(:time_series,
      monitoring_location: usbr,
      selected_for_display: true,
      has_continuous_anchor: true,
      continuous_newest_at: 3.days.ago)

    ids = MonitoringLocation.iv_repair_candidate_ids
    assert_includes ids, usgs.id
    assert_not_includes ids, usbr.id
  end
end
