require "test_helper"

class LatestObservationSyncTest < ActiveSupport::TestCase
  setup do
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
end
