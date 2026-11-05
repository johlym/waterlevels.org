require "test_helper"

class StationCatalogSyncTest < ActiveSupport::TestCase
  setup do
    stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
      .to_return(status: 404, body: "", headers: { "Content-Type" => "application/json" })
  end

  test "national sync skips unsupported USGS state FIPS without aborting" do
    # FIPS 95 is in USGS's Canadian province range (90–98). A national catalog
    # pull surfaces these sites via latest-continuous; we must skip them rather
    # than raise from StateCodes.normalize_postal.
    foreign_location_id = "USGS-09500000"
    domestic_location_id = "USGS-12101000"

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        query = request.uri.query.to_s
        foreign = {
          id: "ts-foreign",
          properties: {
            monitoring_location_id: foreign_location_id,
            time_series_id: "ts-foreign",
            parameter_code: "00065",
            time: "2026-08-02T18:00:00Z",
            value: 3.2,
            unit_of_measure: "ft"
          }
        }
        domestic = {
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
        # 00060 must be non-empty (required) but only the unsupported-state
        # site, so the domestic gage-height path stays a single upsert.
        features =
          if query.include?("parameter_code=00060")
            [ foreign ]
          elsif query.include?("parameter_code=00065")
            [ foreign, domestic ]
          else
            []
          end
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: { features: features, links: [] }.to_json
        }
      end

    location_features = [
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
    ]
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/monitoring-locations/items})
      .to_return do |request|
        query = request.uri.query.to_s
        matched = location_features.select { |feature| query.include?(feature[:id]) }
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: matched.presence || location_features,
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

    assert_nil MonitoringLocation.find_by(provider_location_id: foreign_location_id)
    domestic = MonitoringLocation.find_by!(provider_location_id: domestic_location_id)
    assert_equal "wa", domestic.state_code
    assert domestic.active?
    assert_equal MonitoringLocation.slug_for(domestic.name), domestic.slug
    assert TimeSeries.exists?(provider_series_id: "ts-domestic")
    assert_not TimeSeries.exists?(provider_series_id: "ts-foreign")
  end

  test "re-upserting metadata keeps selected_for_display on existing series" do
    location = create(
      :monitoring_location,
      site_number: "12099550",
      provider_location_id: "USGS-12099550"
    )
    series = create(
      :time_series,
      monitoring_location: location,
      provider_series_id: "ts-boise-gage",
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
      provider_location_id: "USGS-12099550",
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
      provider_location_id: "USGS-12099550",
      has_discharge: false,
      has_temperature: false
    )
    other = create(
      :monitoring_location,
      site_number: "12101000",
      provider_location_id: "USGS-12101000",
      has_discharge: false,
      has_temperature: false
    )
    dirty_series = create(
      :time_series,
      monitoring_location: dirty,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: false,
      provider_series_id: "ts-dirty"
    )
    other_series = create(
      :time_series,
      monitoring_location: other,
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: false,
      provider_series_id: "ts-other"
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

    series = TimeSeries.find_by!(provider_series_id: "ts-flow")
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
      provider_location_id: "USGS-99999999",
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
          elsif code == "00065"
            [ catalog_feature(
              id: "ts-stage",
              monitoring_location_id: flow_location_id,
              parameter_code: "00065",
              value: 2.5,
              unit_of_measure: "ft"
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
    assert TimeSeries.find_by!(provider_series_id: "ts-flow").selected_for_display?

    boom_on_temperature = false
    resume_io = StringIO.new
    StationCatalogSync.new(progress: SyncProgress.new("catalog", io: resume_io, logger: nil)).perform

    assert_match(/resuming catalog completed=00060 remaining=/, resume_io.string)
    assert_equal 1, latest_continuous_counts["00060"]
    assert_nil MonitoringLocation.find_by(id: orphan.id)
    kept = MonitoringLocation.find_by!(provider_location_id: flow_location_id)
    assert TimeSeries.find_by!(provider_series_id: "ts-flow").selected_for_display?
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
      provider_location_id: "USGS-12101000",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )
    series = create(
      :time_series,
      monitoring_location: kept,
      provider_series_id: "ts-flow",
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
      provider_location_id: "USGS-99999999",
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

  test "empty required latest-continuous does not mark complete or prune" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    StationCatalogCheckpoint.clear_all!

    orphan = create(
      :monitoring_location,
      site_number: "99999991",
      provider_location_id: "USGS-99999991",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )
    usbr = create(
      :monitoring_location,
      data_provider: DataProviders::USBR,
      provider_location_id: "USBR-3514",
      site_number: "usbr3514",
      name: "Lake Mead at Hoover Dam",
      slug: "lake-mead-at-hoover-dam"
    )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: { features: [], links: [] }.to_json
      )

    error = assert_raises(Usgs::Client::Error) { StationCatalogSync.new.perform }
    assert_match(/required parameter=00060/, error.message)
    assert MonitoringLocation.exists?(orphan.id)
    assert MonitoringLocation.exists?(usbr.id)
    raw = StationCatalogCheckpoint.read_raw(state: nil)
    assert_equal [], Array(raw && raw["completed_parameter_codes"])
  ensure
    StationCatalogCheckpoint.clear_all!
    Rails.cache = previous_cache
  end

  test "prune keeps discovered locations that have no denormalized tip and ignores non-usgs reservoirs" do
    kept = create(
      :monitoring_location,
      provider_location_id: "USGS-12101000",
      site_number: "12101000",
      latest_observed_at: nil,
      has_water_level: false,
      has_discharge: false,
      has_temperature: false
    )
    orphan = create(
      :monitoring_location,
      provider_location_id: "USGS-99999992",
      site_number: "99999992",
      has_discharge: true,
      latest_observed_at: 1.hour.ago
    )
    usbr = create(
      :monitoring_location,
      data_provider: DataProviders::USBR,
      provider_location_id: "USBR-35993",
      site_number: "usbr35993",
      name: "Lake Mead",
      slug: "lake-mead"
    )

    StationCatalogSync.new.send(:prune_inactive_locations!, [ "USGS-12101000" ])

    assert MonitoringLocation.exists?(kept.id)
    assert MonitoringLocation.exists?(usbr.id)
    assert_nil MonitoringLocation.find_by(id: orphan.id)
  end

  test "latest upsert does not regress a newer hourly tip" do
    location = create(:monitoring_location, provider_location_id: "USGS-12099550", site_number: "12099550")
    series = create(:time_series, monitoring_location: location, provider_series_id: "ts-hourly")
    newer = 1.hour.ago.change(usec: 0)
    older = 6.hours.ago.change(usec: 0)
    LatestObservation.create!(
      time_series: series,
      observed_at: newer,
      value: 10.0,
      unit_of_measure: "ft",
      synced_at: newer
    )

    StationCatalogSync.new.send(:upsert_latest_observations, [ {
      monitoring_location_id: location.provider_location_id,
      time_series_id: series.provider_series_id,
      parameter_code: "00065",
      measurement_kind: "water_level",
      value: 1.0,
      observed_at: older.iso8601,
      unit_of_measure: "ft"
    } ])

    latest = LatestObservation.find_by!(time_series_id: series.id)
    assert_equal newer.to_i, latest.observed_at.to_i
    assert_in_delta 10.0, latest.value, 0.001
  end

  test "latest upsert still advances when discovery is newer than the stored tip" do
    location = create(:monitoring_location, provider_location_id: "USGS-12099551", site_number: "12099551")
    series = create(:time_series, monitoring_location: location, provider_series_id: "ts-newer")
    older = 6.hours.ago.change(usec: 0)
    newer = 1.hour.ago.change(usec: 0)
    LatestObservation.create!(
      time_series: series,
      observed_at: older,
      value: 1.0,
      unit_of_measure: "ft",
      synced_at: older
    )

    StationCatalogSync.new.send(:upsert_latest_observations, [ {
      monitoring_location_id: location.provider_location_id,
      time_series_id: series.provider_series_id,
      parameter_code: "00065",
      measurement_kind: "water_level",
      value: 12.5,
      observed_at: newer.iso8601,
      unit_of_measure: "ft"
    } ])

    latest = LatestObservation.find_by!(time_series_id: series.id)
    assert_equal newer.to_i, latest.observed_at.to_i
    assert_in_delta 12.5, latest.value, 0.001
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
