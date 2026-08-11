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

  test "continuous ingest flushes upserts in batches" do
    features = 12.times.map do |i|
      {
        id: i.to_s,
        properties: {
          time_series_id: @series.usgs_time_series_id,
          parameter_code: "62614",
          time: (12.hours.ago + (i * 15).minutes).utc.iso8601,
          value: 500 + i,
          approval_status: "Provisional"
        }
      }
    end
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: { features: features, links: [] }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    AppConfig.write!(:continuous_upsert_batch, 5)

    HistoryIngestion.new(monitoring_location: @location, range: "7d").perform
    assert_equal 12, @series.continuous_observations.count
    assert_in_delta 511.0, @series.continuous_observations.order(:observed_at).last.value, 0.001
  ensure
    AppConfig.reset!(:continuous_upsert_batch)
  end

  test "continuous ingest dedupes duplicate timestamps before upsert_all" do
    observed_at = "2026-08-01T12:00:00Z"
    features = [
      {
        id: "1",
        properties: {
          time_series_id: @series.usgs_time_series_id,
          parameter_code: "62614",
          time: observed_at,
          value: 540.1,
          approval_status: "Provisional",
          qualifier: "P"
        }
      },
      {
        id: "2",
        properties: {
          time_series_id: @series.usgs_time_series_id,
          parameter_code: "62614",
          time: observed_at,
          value: 540.9,
          approval_status: "Approved",
          qualifier: "A"
        }
      },
      {
        id: "3",
        properties: {
          time_series_id: @series.usgs_time_series_id,
          parameter_code: "62614",
          time: "2026-08-01T12:15:00Z",
          value: 541.0,
          approval_status: "Provisional"
        }
      }
    ]
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: { features: features, links: [] }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    assert_nothing_raised do
      HistoryIngestion.new(monitoring_location: @location, range: "7d").perform
    end

    observations = @series.continuous_observations.order(:observed_at)
    assert_equal 2, observations.count
    first = observations.first
    assert_in_delta 540.9, first.value, 0.001
    assert_equal "Approved", first.approval_status
    assert_equal "A", first.qualifier
    assert_in_delta 541.0, observations.last.value, 0.001
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

      assert_match(/datetime=2026-06-29T/, continuous_query) # 35 days before Aug 3
      assert_match(/datetime=2025-08-03/, daily_query)
      assert_equal 1, @series.continuous_observations.count
      assert_equal 1, @series.daily_observations.count
      assert_equal 11.months.ago.to_date, @series.daily_observations.first.observed_on
    end
  end

  test "skips USGS calls when continuous daily and peaks are already loaded" do
    seed_continuous_coverage!(
      @series,
      from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
      to: 1.hour.ago
    )
    DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
    DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
    PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
  end

  test "continuous request fills older gap when only recent tips exist" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      # Mimic LatestObservationSync tip-only archive: a few recent IV points and
      # complete daily year history, but nothing for the rest of the 30d/35d window.
      # Keep tip cluster dense so only the leading archive hole is requested.
      seed_continuous_coverage!(
        @series,
        from: Time.zone.parse("2026-08-01 00:00:00"),
        to: Time.zone.parse("2026-08-03 11:00:00"),
        step: 1.hour
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
      assert_match(%r{datetime=2026-06-29T.*/2026-08-01T00:00:00}, captured)
      refute_match(%r{datetime=2026-06-29T.*/2026-08-03T}, captured)
    end
  end

  test "continuous request fills interior gap even when tip is fresh" do
    travel_to Time.zone.parse("2026-08-10 14:00:00 UTC") do
      # Dense coverage through last night, then a tip this morning — the overnight
      # hole is what tip sync leaves behind when hourly polls are missed.
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: Time.zone.parse("2026-08-09 20:00:00 UTC"),
        step: 1.hour
      )
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-08-10 13:30:00 UTC"),
        value: 2.0
      )
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

      captured = []
      stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .to_return do |request|
          captured << CGI.unescape(request.uri.query.to_s)
          { status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json }
        end

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      joined = captured.join(" ")
      assert_match(%r{datetime=2026-08-09T19:30:00}, joined)
      assert_match(%r{2026-08-10T14:00:00}, joined)
      assert_equal 1, captured.size
    end
  end

  test "continuous tip refresh uses overlap when newest tip is stale" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      # Dense archive through the stale tip so only tip→now is requested.
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: Time.zone.parse("2026-07-20 12:00:00"),
        step: 1.hour
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
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 1.hour.ago
      )
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
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 1.hour.ago
      )
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")

      HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov}
    end
  end

  test "3y ingest skips daily fetch when deep anchor exists only in archive shards" do
    travel_to Time.zone.parse("2026-08-03 12:00:00") do
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 1.hour.ago
      )
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)
      PeakObservation.create!(time_series: @series, water_year: 2025, value: 9.0, peak_kind: "high")
      deep_day = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
      DailyArchiveShard.create!(
        time_series: @series,
        year: deep_day.year,
        object_key: "daily/v1/#{@series.id}/#{deep_day.year}.json.gz",
        content_sha256: "archive-only",
        point_count: 1,
        min_on: deep_day,
        max_on: deep_day,
        source_mix: "usgs",
        synced_at: Time.current
      )

      HistoryIngestion.new(monitoring_location: @location, range: "3y").perform

      assert_not_requested :get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items}
    end
  end

  test "advances latest tips and denormalized map columns from fresher continuous points" do
    older = 4.days.ago.utc.change(sec: 0)
    newer = 1.hour.ago.utc.change(sec: 0)
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
    seed_continuous_coverage!(
      @series,
      from: newer - HistoryIngestion::CONTINUOUS_RETENTION,
      to: newer,
      step: 1.hour,
      value: 500.0
    )
    assert ContinuousObservation.where(time_series_id: @series.id, observed_at: newer).update_all(value: 541.5).positive?
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

  test "marks usgs_daily_absent when daily API returns sibling params but not this series" do
    stage = @series
    stage.update!(parameter_code: "00065", measurement_kind: "water_level", usgs_time_series_id: "ts-stage-iv")
    flow = create(
      :time_series,
      monitoring_location: @location,
      parameter_code: "00060",
      measurement_kind: "discharge",
      usgs_time_series_id: "ts-flow-dv"
    )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [
            {
              id: "1",
              properties: {
                time_series_id: stage.usgs_time_series_id,
                parameter_code: "00065",
                time: 1.hour.ago.utc.iso8601,
                value: 5.7
              }
            },
            {
              id: "2",
              properties: {
                time_series_id: flow.usgs_time_series_id,
                parameter_code: "00060",
                time: 1.hour.ago.utc.iso8601,
                value: 11.0
              }
            }
          ],
          links: []
        }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/geo+json" },
        body: {
          features: [
            {
              id: "d1",
              properties: {
                time_series_id: "other-daily-id",
                parameter_code: "00060",
                time: 11.months.ago.to_date.iso8601,
                value: 8.0
              }
            },
            {
              id: "d2",
              properties: {
                time_series_id: "other-daily-id",
                parameter_code: "00060",
                time: Date.current.iso8601,
                value: 9.0
              }
            }
          ],
          links: []
        }.to_json
      )
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    # Dense continuous coverage so only daily gates would keep needs_history_backfill.
    [ stage, flow ].each do |series|
      seed_continuous_coverage!(
        series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: 2.hours.ago
      )
    end

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    assert stage.reload.usgs_daily_absent?
    refute flow.reload.usgs_daily_absent?
    refute @location.reload.missing_year_history?
    refute @location.needs_history_backfill?
  end

  test "does not mark usgs_daily_absent for long-inactive series with empty recent DV" do
    @series.update!(
      parameter_code: "00060",
      measurement_kind: "discharge",
      usgs_time_series_id: "ts-dead-flow",
      ends_at: Time.zone.parse("2008-06-01")
    )
    LatestObservation.create!(
      time_series: @series,
      observed_at: Time.zone.parse("2008-06-01"),
      value: 3.0,
      unit_of_measure: "ft3/s",
      synced_at: Time.current
    )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    refute @series.reload.usgs_daily_absent?
    refute @location.reload.needs_history_backfill?
  end

  test "clears stale usgs_daily_absent when series has no recent continuous evidence" do
    @series.update!(
      parameter_code: "00060",
      measurement_kind: "discharge",
      usgs_daily_absent: true,
      ends_at: Time.zone.parse("2008-06-01")
    )
    LatestObservation.create!(
      time_series: @series,
      observed_at: Time.zone.parse("2008-06-01"),
      value: 3.0,
      unit_of_measure: "ft3/s",
      synced_at: Time.current
    )

    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})
      .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)

    HistoryIngestion.new(monitoring_location: @location, range: "1y").perform

    refute @series.reload.usgs_daily_absent?
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

  test "time_series_ids_with_tip_sync_gaps finds fresh tip with stale previous point" do
    @series.update!(selected_for_display: true)
    ContinuousObservation.create!(time_series: @series, observed_at: 12.hours.ago, value: 1.0)
    ContinuousObservation.create!(time_series: @series, observed_at: 30.minutes.ago, value: 1.1)

    healthy = create(:time_series, monitoring_location: @location, selected_for_display: true)
    ContinuousObservation.create!(time_series: healthy, observed_at: 90.minutes.ago, value: 2.0)
    ContinuousObservation.create!(time_series: healthy, observed_at: 30.minutes.ago, value: 2.1)

    ids = HistoryIngestion.time_series_ids_with_tip_sync_gaps
    assert_includes ids, @series.id
    refute_includes ids, healthy.id
  end

  test "iv_repair mode fetches continuous only on the iv_repair key" do
    previous = {
      "USGS_API_HISTORY_IVREPAIR_KEY" => ENV["USGS_API_HISTORY_IVREPAIR_KEY"],
      "USGS_API_HISTORY_CONTINUOUS_KEY" => ENV["USGS_API_HISTORY_CONTINUOUS_KEY"],
      "USGS_API_HISTORY_DAILY_KEY" => ENV["USGS_API_HISTORY_DAILY_KEY"],
      "USGS_API_HISTORY_PEAKS_KEY" => ENV["USGS_API_HISTORY_PEAKS_KEY"]
    }
    ENV["USGS_API_HISTORY_IVREPAIR_KEY"] = "hist-iv-repair"
    ENV["USGS_API_HISTORY_CONTINUOUS_KEY"] = "hist-continuous"
    ENV["USGS_API_HISTORY_DAILY_KEY"] = "hist-daily"
    ENV["USGS_API_HISTORY_PEAKS_KEY"] = "hist-peaks"

    travel_to Time.zone.parse("2026-08-10 14:00:00 UTC") do
      seed_continuous_coverage!(
        @series,
        from: HistoryIngestion::CONTINUOUS_RETENTION.ago,
        to: Time.zone.parse("2026-08-09 20:00:00 UTC"),
        step: 1.hour
      )
      ContinuousObservation.create!(
        time_series: @series,
        observed_at: Time.zone.parse("2026-08-10 13:30:00 UTC"),
        value: 2.0
      )
      DailyObservation.create!(time_series: @series, observed_on: 11.months.ago.to_date, value: 1.0)
      DailyObservation.create!(time_series: @series, observed_on: Date.current, value: 1.1)

      continuous_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/continuous/items})
        .with(headers: { "X-Api-Key" => "hist-iv-repair" })
        .to_return(status: 200, headers: { "Content-Type" => "application/geo+json" }, body: { features: [], links: [] }.to_json)
      daily_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/daily/items})
      peaks_stub = stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v0/collections/peaks/items})

      HistoryIngestion.new(
        monitoring_location: @location,
        range: "1y",
        mode: HistoryIngestion::MODE_IV_REPAIR
      ).perform

      assert_requested continuous_stub
      assert_not_requested daily_stub
      assert_not_requested peaks_stub
    end
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
