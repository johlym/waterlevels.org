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
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
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
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
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
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
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
    ContinuousObservation.create!(
      time_series: @series,
      observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
      value: 0.9
    )
    ContinuousObservation.create!(time_series: @series, observed_at: 1.hour.ago, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
    PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
  end

  test "continuous request fills older gap when only recent tips exist" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      # Mimic LatestObservationSync tip-only archive: a few recent IV points and
      # complete daily year history, but nothing for the rest of the 30d/90d window.
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-08-01 00:00:00"),
        value: 1.0
      )
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-08-03 11:00:00"),
        value: 1.1
      )
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

      captured = nil
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return do |request|
          captured = CGI.unescape(request.uri.query.to_s)
          { status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json }
        end

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      # Older gap only: retention window → oldest local tip (fresh tip skips tip refresh).
      assert_match(%r{datetime=2026-05-05T.*/2026-08-01T00:00:00}, captured)
      refute_match(%r{datetime=2026-05-05T.*/2026-08-03T}, captured)
    end
  end

  test "continuous tip refresh uses overlap when newest tip is stale" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
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

      # 30-minute overlap from newest tip 2026-07-20T12:00:00; older archive already present.
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

  test "3y ingest requests the older daily gap beyond existing year history" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
      ContinuousObservation.create!(time_series: @series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

      captured = nil
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
        .to_return do |request|
          captured = CGI.unescape(request.uri.query.to_s)
          {
            status: 200,
            headers: { "Content-Type" => "application/geo+json" },
            body: {
              features: [
                {
                  id: "d3",
                  properties: {
                    time_series_id: @series.usgs_time_series_id,
                    parameter_code: "62614",
                    time: 35.months.ago.to_date.iso8601,
                    value: 537.0,
                    approval_status: "Approved"
                  }
                }
              ],
              links: []
            }.to_json
          }
        end

      HistoryIngestion.new(monitoring_location: @location, range: "3y").perform

      assert_match(%r{datetime=2023-08-03/}, captured)
      refute_match(%r{datetime=2025-08-03/2026-08-03}, captured)
      assert_equal 35.months.ago.to_date, @series.daily_observations.minimum(:observed_on)
    end
  end

  test "1y ingest does not pull the 3y daily gap when year history is already present" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
        value: 0.9
      )
      ContinuousObservation.create!(time_series: @series, observed_at: 1.hour.ago, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
    end
  end

  test "advances latest tips and denormalized map columns from fresher continuous points" do
    older = 4.days.ago.change(sec: 0)
    newer = 1.hour.ago.change(sec: 0)
    @location.update!(
      latest_water_level_value: 500.0,
      latest_water_level_parameter_code: "62614",
      latest_water_level_unit: "ft",
      latest_observed_at: older
    )
    LatestObservation.create!(
      time_series: @series,
      value: 500.0,
      unit_of_measure: "ft",
      observed_at: older,
      synced_at: older
    )
    ContinuousObservation.create!(
      time_series: @series,
      observed_at: HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.ago,
      value: 499.0
    )
    ContinuousObservation.create!(time_series: @series, observed_at: older, value: 500.0)
    ContinuousObservation.create!(time_series: @series, observed_at: newer, value: 541.5)
    DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 500.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 541.0)
    PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    latest = LatestObservation.find_by!(time_series_id: @series.id)
    assert_equal newer, latest.observed_at
    assert_in_delta 541.5, latest.value, 0.001

    @location.reload
    assert_in_delta 541.5, @location.latest_water_level_value, 0.001
    assert_equal newer, @location.latest_observed_at
  end

  test "skips USGS temperature fault sentinels during continuous ingest and tip denormalize" do
    temperature = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00010",
      measurement_kind: "temperature",
      selected_for_display: true,
      usgs_time_series_id: "ts-temperature"
    )
    @location.update!(has_temperature: true, latest_temperature_c: 11.0)

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [
            {
              id: "1",
              properties: {
                time_series_id: temperature.usgs_time_series_id,
                parameter_code: "00010",
                time: 1.hour.ago.utc.iso8601,
                value: -100_000,
                approval_status: "Provisional"
              }
            },
            {
              id: "2",
              properties: {
                time_series_id: temperature.usgs_time_series_id,
                parameter_code: "00010",
                time: 2.hours.ago.utc.iso8601,
                value: 14.2,
                approval_status: "Provisional"
              }
            }
          ],
          links: []
        }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    assert_nothing_raised do
      HistoryIngestion.new(monitoring_location: @location, range: "7d").perform
    end

    assert_equal [ 14.2 ], temperature.continuous_observations.order(:observed_at).map { |o| o.value.to_f }
    latest = LatestObservation.find_by!(time_series_id: temperature.id)
    assert_in_delta 14.2, latest.value, 0.001
    assert_in_delta 14.2, @location.reload.latest_temperature_c, 0.001
  end

  test "coalesces multiple parameter codes into one continuous request per location" do
    discharge = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      usgs_time_series_id: "ts-discharge"
    )

    continuous_requests = []
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return do |request|
        continuous_requests << CGI.unescape(request.uri.query.to_s)
        {
          status: 200,
          headers: { "Content-Type" => "application/geo+json" },
          body: {
            features: [
              {
                id: "1",
                properties: {
                  time_series_id: @series.usgs_time_series_id,
                  parameter_code: "62614",
                  time: 1.hour.ago.utc.iso8601,
                  value: 10.0
                }
              },
              {
                id: "2",
                properties: {
                  time_series_id: discharge.usgs_time_series_id,
                  parameter_code: "00060",
                  time: 1.hour.ago.utc.iso8601,
                  value: 100.0
                }
              }
            ],
            links: []
          }.to_json
        }
      end
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    assert_equal 1, continuous_requests.size
    assert_match(/parameter_code=62614,00060|parameter_code=00060,62614/, continuous_requests.first)
    assert_equal 1, @series.continuous_observations.count
    assert_equal 1, discharge.continuous_observations.count
  end
end
