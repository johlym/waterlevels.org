require "test_helper"

class StationCatalogCleanupTest < ActiveSupport::TestCase
  test "audit reports errant station categories" do
    keep = create(:monitoring_location, site_type_code: "ST", has_discharge: true, latest_observed_at: 1.hour.ago)
    create(:time_series, monitoring_location: keep, selected_for_display: true)

    well = create(
      :monitoring_location,
      site_number: "90000001",
      usgs_monitoring_location_id: "USGS-90000001",
      site_type_code: "GW",
      has_water_level: false,
      has_discharge: false,
      has_temperature: false,
      latest_observed_at: nil
    )
    never_observed = create(
      :monitoring_location,
      site_number: "90000002",
      usgs_monitoring_location_id: "USGS-90000002",
      site_type_code: "ST",
      has_discharge: true,
      latest_observed_at: nil
    )
    create(:time_series, monitoring_location: never_observed, selected_for_display: true)

    report = StationCatalogCleanup.audit
    counts = report[:categories].to_h { |category| [ category[:key], category[:count] ] }

    assert_equal 3, report[:total]
    assert counts[:non_water_body] >= 1
    assert counts[:never_observed] >= 1
    assert_includes report[:categories].flat_map { |category| category[:sample_site_numbers] }, well.site_number
  end

  test "purge dry-run leaves rows intact and apply deletes them" do
    keep = create(:monitoring_location, site_type_code: "ST", has_discharge: true, latest_observed_at: 1.hour.ago)
    create(:time_series, monitoring_location: keep, selected_for_display: true)
    create(
      :monitoring_location,
      site_number: "90000003",
      usgs_monitoring_location_id: "USGS-90000003",
      site_type_code: "GW",
      has_water_level: false,
      has_discharge: false,
      has_temperature: false,
      latest_observed_at: nil
    )

    dry = StationCatalogCleanup.purge!(apply: false)
    assert dry[:dry_run]
    assert dry[:removable].positive?
    assert_equal 0, dry[:deleted]
    assert_equal 2, MonitoringLocation.count

    applied = StationCatalogCleanup.purge!(apply: true)
    assert_not applied[:dry_run]
    assert applied[:deleted].positive?
    assert_equal [ keep.id ], MonitoringLocation.pluck(:id)
  end
end
