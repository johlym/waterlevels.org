require "test_helper"

class HistoryIngestionTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location, usgs_monitoring_location_id: "USGS-12101000")
    @series = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "62614",
      measurement_kind: "water_level",
      usgs_time_series_id: "ts-lake-tapps"
    )
  end

  test "continuous ingest uses explicit RFC3339 datetime intervals" do
    captured = nil
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return do |request|
        captured = request.uri.query
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "1",
                properties: {
                  time: "2026-08-01T12:00:00Z",
                  value: 540.1,
                  approval_status: "Provisional"
                }
              }
            ],
            links: []
          }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    HistoryIngestion.new(monitoring_location: @location, range: "7d").perform

    assert_match(/datetime=\d{4}-\d{2}-\d{2}T/, captured)
    refute_includes captured, "datetime=P7D"
    assert_equal 1, @series.continuous_observations.count
    assert_in_delta 540.1, @series.continuous_observations.first.value, 0.001
  end
end
