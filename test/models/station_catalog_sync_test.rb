require "test_helper"

class StationCatalogSyncTest < ActiveSupport::TestCase
  test "national sync skips unsupported USGS state FIPS without aborting" do
    # FIPS 95 is in USGS's Canadian province range (90–98). A national catalog
    # pull surfaces these sites via latest-continuous; we must skip them rather
    # than raise from StateCodes.normalize_postal.
    foreign_location_id = "USGS-09500000"
    domestic_location_id = "USGS-12101000"

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        features =
          if request.uri.query.to_s.include?("parameter_code=00065")
            [
              {
                id: "ts-foreign",
                properties: {
                  monitoring_location_id: foreign_location_id,
                  time_series_id: "ts-foreign",
                  parameter_code: "00065",
                  time: "2026-08-02T18:00:00Z",
                  value: 3.2,
                  unit_of_measure: "ft"
                }
              },
              {
                id: "ts-domestic",
                properties: {
                  monitoring_location_id: domestic_location_id,
                  time_series_id: "ts-domestic",
                  parameter_code: "00065",
                  time: "2026-08-02T18:00:00Z",
                  value: 12.5,
                  unit_of_measure: "ft"
                }
              }
            ]
          else
            []
          end
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: { features: features, links: [] }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return do |_request|
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: foreign_location_id,
                geometry: { type: "Point", coordinates: [ -75.7, 45.4 ] },
                properties: {
                  agency_code: "USGS",
                  monitoring_location_number: "09500000",
                  monitoring_location_name: "OTTAWA RIVER AT DEMO, ON",
                  site_type_code: "ST",
                  site_type: "Stream",
                  state_code: "95",
                  state_name: "Ontario"
                }
              },
              {
                id: domestic_location_id,
                geometry: { type: "Point", coordinates: [ -122.2, 47.6 ] },
                properties: {
                  agency_code: "USGS",
                  monitoring_location_number: "12101000",
                  monitoring_location_name: "CEDAR RIVER NEAR DEMO, WA",
                  site_type_code: "ST",
                  site_type: "Stream",
                  state_code: "53",
                  state_name: "Washington",
                  county_name: "King",
                  time_zone_abbreviation: "PST"
                }
              }
            ],
            links: []
          }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/time-series-metadata/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [ {
            id: "ts-domestic",
            properties: {
              parameter_name: "Gage height",
              parameter_description: "Gage height, feet",
              unit_of_measure: "ft",
              primary: "Primary"
            }
          } ],
          links: []
        }.to_json
      )

    assert_nothing_raised { StationCatalogSync.new(state: nil).perform }

    assert_nil MonitoringLocation.find_by(usgs_monitoring_location_id: foreign_location_id)
    domestic = MonitoringLocation.find_by!(usgs_monitoring_location_id: domestic_location_id)
    assert_equal "wa", domestic.state_code
    assert domestic.active?
    assert_equal MonitoringLocation.slug_for(domestic.name), domestic.slug
    assert TimeSeries.exists?(usgs_time_series_id: "ts-domestic")
    assert_not TimeSeries.exists?(usgs_time_series_id: "ts-foreign")
  end

  test "re-upserting metadata keeps selected_for_display on existing series" do
    location = create(
      :monitoring_location,
      site_number: "12099550",
      usgs_monitoring_location_id: "USGS-12099550"
    )
    series = create(
      :time_series,
      monitoring_location: location,
      usgs_time_series_id: "ts-boise-gage",
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/time-series-metadata/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [ {
            id: "ts-boise-gage",
            properties: {
              parameter_name: "Gage height",
              parameter_description: "Gage height, feet",
              unit_of_measure: "ft",
              primary: "Primary"
            }
          } ],
          links: []
        }.to_json
      )

    StationCatalogSync.new.send(
      :upsert_time_series_for,
      [ {
        monitoring_location_id: "USGS-12099550",
        time_series_id: "ts-boise-gage",
        parameter_code: "00065",
        measurement_kind: "water_level",
        unit_of_measure: "ft"
      } ]
    )

    assert series.reload.selected_for_display?
    assert_equal "ft", series.unit_of_measure
  end

  test "re-upserting location metadata keeps created_at slug and active" do
    created_at = Time.zone.parse("2026-01-15 12:00:00 UTC")
    location = create(
      :monitoring_location,
      site_number: "12099550",
      usgs_monitoring_location_id: "USGS-12099550",
      name: "BOISE CREEK AT DEMO, WA",
      slug: "custom-stable-slug",
      active: false,
      created_at: created_at,
      has_water_level: true,
      latest_water_level_value: 16.72,
      flood_category: "minor"
    )
    incoming_name = "BOISE CREEK AT 252ND AVE NE NEAR BUCKLEY, WA"
    derived_names = MonitoringLocation.derived_names_for(incoming_name)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [ {
            id: "USGS-12099550",
            geometry: { type: "Point", coordinates: [ -122.0, 47.2 ] },
            properties: {
              agency_code: "USGS",
              monitoring_location_number: "12099550",
              monitoring_location_name: incoming_name,
              site_type_code: "ST",
              site_type: "Stream",
              state_code: "53",
              state_name: "Washington",
              county_name: "King",
              time_zone_abbreviation: "PST"
            }
          } ],
          links: []
        }.to_json
      )

    StationCatalogSync.new.send(
      :upsert_locations_for,
      [ { monitoring_location_id: "USGS-12099550" } ]
    )

    location.reload
    assert_equal created_at, location.created_at
    assert_equal "custom-stable-slug", location.slug
    assert_not location.active?
    assert_equal incoming_name, location.name
    assert_equal derived_names[:display_name], location.display_name
    assert_equal derived_names[:search_name], location.search_name
    assert_in_delta 16.72, location.latest_water_level_value, 0.001
    assert_equal "minor", location.flood_category
    assert location.has_water_level?
    assert_not_nil location.metadata_synced_at
  end

  test "dirty display reselect only apply!s the touched USGS locations" do
    dirty = create(
      :monitoring_location,
      site_number: "12099550",
      usgs_monitoring_location_id: "USGS-12099550",
      has_discharge: false,
      has_temperature: false
    )
    other = create(
      :monitoring_location,
      site_number: "12101000",
      usgs_monitoring_location_id: "USGS-12101000",
      has_discharge: false,
      has_temperature: false
    )
    dirty_series = create(
      :time_series,
      monitoring_location: dirty,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: false,
      usgs_time_series_id: "ts-dirty"
    )
    other_series = create(
      :time_series,
      monitoring_location: other,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: false,
      usgs_time_series_id: "ts-other"
    )
    LatestObservation.create!(
      time_series: dirty_series,
      value: 16.72,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    LatestObservation.create!(
      time_series: other_series,
      value: 4.2,
      unit_of_measure: "ft",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )

    StationCatalogSync.new.send(:select_display_series, usgs_ids: [ "USGS-12099550" ])

    assert dirty_series.reload.selected_for_display?
    refute other_series.reload.selected_for_display?
  end

  test "catalog abort after the first parameter still selects that series" do
    domestic_location_id = "USGS-12101000"

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        query = request.uri.query.to_s
        raise Usgs::Client::Error, "USGS 503: boom" if query.include?("parameter_code=00010")

        features =
          if query.include?("parameter_code=00060")
            [ {
              id: "ts-flow",
              properties: {
                monitoring_location_id: domestic_location_id,
                time_series_id: "ts-flow",
                parameter_code: "00060",
                time: "2026-08-24T03:15:00Z",
                value: 4.13,
                unit_of_measure: "ft3/s"
              }
            } ]
          else
            []
          end
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: { features: features, links: [] }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [ {
            id: domestic_location_id,
            geometry: { type: "Point", coordinates: [ -122.2, 47.6 ] },
            properties: {
              agency_code: "USGS",
              monitoring_location_number: "12101000",
              monitoring_location_name: "CEDAR RIVER NEAR DEMO, WA",
              site_type_code: "ST",
              site_type: "Stream",
              state_code: "53",
              state_name: "Washington",
              county_name: "King",
              time_zone_abbreviation: "PST"
            }
          } ],
          links: []
        }.to_json
      )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/time-series-metadata/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [ {
            id: "ts-flow",
            properties: {
              parameter_name: "Discharge",
              parameter_description: "Discharge, cubic feet per second",
              unit_of_measure: "ft3/s",
              primary: "Primary"
            }
          } ],
          links: []
        }.to_json
      )

    assert_raises(Usgs::Client::Error) { StationCatalogSync.new(state: nil).perform }

    series = TimeSeries.find_by!(usgs_time_series_id: "ts-flow")
    assert series.selected_for_display?
  end
end
