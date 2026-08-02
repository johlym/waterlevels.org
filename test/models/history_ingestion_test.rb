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

  test "skips USGS calls when continuous daily and peaks are already loaded" do
    ContinuousObservation.create!(time_series: @series, observed_at: 1.hour.ago, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
    PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
  end

  test "continuous request starts from newest local tip instead of full window" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-08-01 00:00:00"),
        value: 1.0
      )
      # Tip within CONTINUOUS_FRESHNESS would skip continuous; use an older tip
      # so a gap pull is required and we can assert the narrowed datetime bound.
      @series.continuous_observations.delete_all
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-07-20 12:00:00"),
        value: 1.0
      )

      captured = nil
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return do |request|
          captured = CGI.unescape(request.uri.query.to_s)
          { status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json }
        end
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      # 30-minute overlap from newest tip 2026-07-20T12:00:00
      assert_match(%r{datetime=2026-07-20T11:30:00}, captured)
      refute_match(%r{datetime=2026-05-05T}, captured)
    end
  end

  test "daily request only fills the older gap when recent days already exist" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      DailyObservation.create!(time_series: @series, observed_on: Date.new(2026, 7, 1), value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.new(2026, 8, 3), value: 1.1)

      captured = nil
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
        .to_return do |request|
          captured = CGI.unescape(request.uri.query.to_s)
          { status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json }
        end
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      assert_match(%r{datetime=2025-08-03/2026-06-30}, captured)
      refute_match(%r{datetime=2025-08-03/2026-08-03}, captured)
    end
  end
end
