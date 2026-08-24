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
end
