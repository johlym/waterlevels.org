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

  test "1y ingest loads daily year history and continuous within retention" do
    continuous_query = nil
    daily_query = nil

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return do |request|
        continuous_query = request.uri.query
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "1",
                properties: {
                  time: 1.day.ago.utc.iso8601,
                  value: 540.1,
                  approval_status: "Provisional"
                }
              }
            ],
            links: []
          }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return do |request|
        daily_query = request.uri.query
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "d1",
                properties: {
                  time: 11.months.ago.to_date.iso8601,
                  value: 538.0,
                  approval_status: "Approved"
                }
              }
            ],
            links: []
          }.to_json
        }
      end

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      assert_match(/datetime=2026-05-05T/, continuous_query) # 90 days before Aug 3
      assert_match(/datetime=2025-08-03/, daily_query)
      assert_equal 1, @series.continuous_observations.count
      assert_equal 1, @series.daily_observations.count
      assert_equal 11.months.ago.to_date, @series.daily_observations.first.observed_on
    end
  end
end
