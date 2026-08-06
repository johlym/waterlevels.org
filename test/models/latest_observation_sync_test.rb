require "test_helper"

class LatestObservationSyncTest < ActiveSupport::TestCase
  setup do
    AdminDashboardStats.clear_tip_refresh!
    @location = create(:monitoring_location, site_number: "12101000", state_code: "wa")
    @series = create(
      :time_series,
      monitoring_location: @location,
      usgs_time_series_id: "ts-latest-sync",
      parameter_code: "00065",
      measurement_kind: "water_level",
      selected_for_display: true
    )
  end

  test "upserts latest and appends the tip into continuous_observations" do
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        features =
          if request.uri.query.to_s.include?("parameter_code=00065")
            [ {
              id: "ts-latest-sync",
              properties: {
                time_series_id: "ts-latest-sync",
                time: "2026-08-02T18:00:00Z",
                value: 12.5,
                unit_of_measure: "ft",
                approval_status: "Provisional"
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

    LatestObservationSync.new(state: "wa").perform

    latest = LatestObservation.find_by!(time_series_id: @series.id)
    assert_in_delta 12.5, latest.value, 0.001
    assert_equal Time.zone.parse("2026-08-02T18:00:00Z"), latest.observed_at

    continuous = ContinuousObservation.find_by!(time_series_id: @series.id, observed_at: latest.observed_at)
    assert_in_delta 12.5, continuous.value, 0.001

    tip = AdminDashboardStats.last_tip_refresh
    assert_equal 1, tip[:stations_updated]
    assert_equal 1, tip[:series_upserted]
    assert_equal "wa", tip[:state]
  end

  test "purges Cloudflare cache tags after warming when credentials are set" do
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    purge = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/zone-test/purge_cache")
      .to_return(status: 200, body: { success: true }.to_json, headers: { "Content-Type" => "application/json" })

    previous_token = ENV["CLOUDFLARE_API_TOKEN"]
    previous_zone = ENV["CLOUDFLARE_ZONE_ID"]
    ENV["CLOUDFLARE_API_TOKEN"] = "token-test"
    ENV["CLOUDFLARE_ZONE_ID"] = "zone-test"
    begin
      LatestObservationSync.new(state: "wa").perform
    ensure
      previous_token ? ENV["CLOUDFLARE_API_TOKEN"] = previous_token : ENV.delete("CLOUDFLARE_API_TOKEN")
      previous_zone ? ENV["CLOUDFLARE_ZONE_ID"] = previous_zone : ENV.delete("CLOUDFLARE_ZONE_ID")
    end

    assert_requested purge
  end

  test "denormalizes map tip columns even when a later parameter sync fails" do
    @location.update!(
      latest_water_level_value: 1.0,
      latest_water_level_parameter_code: "00065",
      latest_water_level_unit: "ft",
      latest_observed_at: 3.days.ago
    )

    seen = []
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        code = request.uri.query.to_s[/parameter_code=(\d+)/, 1]
        seen << code
        if code == "00065"
          {
            status: 200,
            headers: { "Content-Type" => "application/geo+json" },
            body: {
              features: [ {
                id: "ts-latest-sync",
                properties: {
                  time_series_id: "ts-latest-sync",
                  time: "2026-08-05T16:00:00Z",
                  value: 9.75,
                  unit_of_measure: "ft",
                  approval_status: "Provisional"
                }
              } ],
              links: []
            }.to_json
          }
        elsif seen.include?("00065")
          # Fail after the tip upsert so denormalize must still run.
          raise Usgs::Client::RateLimitError, "429 too many requests"
        else
          {
            status: 200,
            headers: { "Content-Type" => "application/geo+json" },
            body: { features: [], links: [] }.to_json
          }
        end
      end

    assert_raises(Usgs::Client::RateLimitError) do
      LatestObservationSync.new(state: "wa").perform
    end

    @location.reload
    assert_in_delta 9.75, @location.latest_water_level_value, 0.001
    assert_equal Time.zone.parse("2026-08-05T16:00:00Z"), @location.latest_observed_at
    assert_includes seen, "00065"
  end

  test "skips USGS temperature fault sentinels instead of overflowing tip columns" do
    temperature = create(
      :time_series,
      monitoring_location: @location,
      usgs_time_series_id: "ts-temp-sync",
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true
    )
    @location.update!(has_temperature: true, latest_temperature_c: 10.0)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/latest-continuous/items})
      .to_return do |request|
        features =
          if request.uri.query.to_s.include?("parameter_code=00010")
            [ {
              id: "ts-temp-sync",
              properties: {
                time_series_id: "ts-temp-sync",
                time: "2026-08-05T18:00:00Z",
                value: -100_000,
                unit_of_measure: "degC",
                approval_status: "Provisional"
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

    assert_nothing_raised { LatestObservationSync.new(state: "wa").perform }

    assert_nil LatestObservation.find_by(time_series_id: temperature.id)
    assert_equal 0, ContinuousObservation.where(time_series_id: temperature.id).count
    # No plausible tip remains, so denormalize clears the map column instead of writing -100000.
    assert_nil @location.reload.latest_temperature_c
  end
end
