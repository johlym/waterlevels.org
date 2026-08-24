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

  test "resume skips a completed parameter and does not prune its locations" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    StationCatalogCheckpoint.clear_all!

    flow_location_id = "USGS-12101000"
    orphan = create(
      :monitoring_location,
      site_number: "99999999",
      usgs_monitoring_location_id: "USGS-99999999",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )
    latest_continuous_counts = Hash.new(0)
    boom_on_temperature = true

    stub_catalog_collections(
      latest_continuous: lambda do |request|
        query = request.uri.query.to_s
        code = query[/parameter_code=(\d+)/, 1]
        latest_continuous_counts[code] += 1
        raise Usgs::Client::Error, "USGS 503: boom" if boom_on_temperature && code == "00010"

        features =
          if code == "00060"
            [ catalog_feature(
              id: "ts-flow",
              monitoring_location_id: flow_location_id,
              parameter_code: "00060",
              value: 4.13,
              unit_of_measure: "ft3/s"
            ) ]
          else
            []
          end
        catalog_collection_response(features)
      end,
      locations: [ catalog_location_feature(flow_location_id) ],
      time_series: [ catalog_time_series_feature("ts-flow", "Discharge", "ft3/s") ]
    )

    io = StringIO.new
    assert_raises(Usgs::Client::Error) do
      StationCatalogSync.new(progress: SyncProgress.new("catalog", io: io, logger: nil)).perform
    end
    assert_match(/starting catalog/, io.string)
    assert_equal 1, latest_continuous_counts["00060"]
    assert TimeSeries.find_by!(usgs_time_series_id: "ts-flow").selected_for_display?

    boom_on_temperature = false
    resume_io = StringIO.new
    StationCatalogSync.new(progress: SyncProgress.new("catalog", io: resume_io, logger: nil)).perform

    assert_match(/resuming catalog completed=00060 remaining=/, resume_io.string)
    assert_equal 1, latest_continuous_counts["00060"]
    assert_nil MonitoringLocation.find_by(id: orphan.id)
    kept = MonitoringLocation.find_by!(usgs_monitoring_location_id: flow_location_id)
    assert TimeSeries.find_by!(usgs_time_series_id: "ts-flow").selected_for_display?
    assert kept.has_discharge?
    assert_nil StationCatalogCheckpoint.read_raw(state: nil)
  ensure
    StationCatalogCheckpoint.clear_all!
    Rails.cache = previous_cache
  end

  test "resume with every parameter completed skips USGS paging and keeps persisted locations" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    StationCatalogCheckpoint.clear_all!

    kept = create(
      :monitoring_location,
      site_number: "12101000",
      usgs_monitoring_location_id: "USGS-12101000",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )
    series = create(
      :time_series,
      monitoring_location: kept,
      usgs_time_series_id: "ts-flow",
      parameter_code: "00060",
      measurement_kind: "discharge",
      selected_for_display: true
    )
    LatestObservation.create!(
      time_series: series,
      value: 4.13,
      unit_of_measure: "ft3/s",
      observed_at: 1.hour.ago,
      synced_at: Time.current
    )
    orphan = create(
      :monitoring_location,
      site_number: "99999999",
      usgs_monitoring_location_id: "USGS-99999999",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )

    checkpoint = StationCatalogCheckpoint.resume_or_start!(state: nil)
    Usgs::ParameterCodes::ALL.each do |code|
      checkpoint.mark_parameter!(
        code,
        kept_location_ids: code == "00060" ? [ "USGS-12101000" ] : [],
        discovered_rows: 0
      )
    end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return { flunk "resume must not re-page a completed latest-continuous collection" }
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return { flunk "resume must not re-fetch location metadata for completed parameters" }
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/time-series-metadata/items})
      .to_return { flunk "resume must not re-fetch time-series metadata for completed parameters" }

    io = StringIO.new
    StationCatalogSync.new(progress: SyncProgress.new("catalog", io: io, logger: nil)).perform

    assert_match(/resuming catalog completed=/, io.string)
    assert_match(/remaining=none/, io.string)
    assert MonitoringLocation.exists?(kept.id)
    assert series.reload.selected_for_display?
    assert_nil MonitoringLocation.find_by(id: orphan.id)
    assert_nil StationCatalogCheckpoint.read_raw(state: nil)
  ensure
    StationCatalogCheckpoint.clear_all!
    Rails.cache = previous_cache
  end

  private

  def stub_catalog_collections(latest_continuous:, locations:, time_series:)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return(&latest_continuous)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: { features: locations, links: [] }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/time-series-metadata/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: { features: time_series, links: [] }.to_json
      )
  end

  def catalog_collection_response(features)
    {
      status: 200,
      headers: { "Content-Type" => "application/geo+json" },
      body: { features: features, links: [] }.to_json
    }
  end

  def catalog_feature(id:, monitoring_location_id:, parameter_code:, value:, unit_of_measure:)
    {
      id: id,
      properties: {
        monitoring_location_id: monitoring_location_id,
        time_series_id: id,
        parameter_code: parameter_code,
        time: "2026-08-24T03:15:00Z",
        value: value,
        unit_of_measure: unit_of_measure
      }
    }
  end

  def catalog_location_feature(usgs_id)
    {
      id: usgs_id,
      geometry: { type: "Point", coordinates: [ -122.2, 47.6 ] },
      properties: {
        agency_code: "USGS",
        monitoring_location_number: usgs_id.to_s.split("-").last,
        monitoring_location_name: "CEDAR RIVER NEAR DEMO, WA",
        site_type_code: "ST",
        site_type: "Stream",
        state_code: "53",
        state_name: "Washington",
        county_name: "King",
        time_zone_abbreviation: "PST"
      }
    }
  end

  def catalog_time_series_feature(id, parameter_name, unit)
    {
      id: id,
      properties: {
        parameter_name: parameter_name,
        parameter_description: "#{parameter_name}, #{unit}",
        unit_of_measure: unit,
        primary: "Primary"
      }
    }
  end
end
