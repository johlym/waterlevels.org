require "test_helper"

module DailyArchive
  class RetentionTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @location = create(:monitoring_location, time_zone: "PST", state_code: "wa")
      @series = create(:time_series, monitoring_location: @location)
      @as_of = Time.utc(2026, 8, 7, 12, 0, 0)
    end

    teardown do
      DailyArchive.reset_store!
      ENV.delete("DAILY_ARCHIVE_PRUNE")
    end

    test "derives day-31 local mean into archive when usgs daily missing" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      day = Date.new(2026, 7, 8) # 30 days before Aug 7 local
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      while t < zone.local(day.year, day.month, day.day, 0, 0, 0) + 1.day
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 8.0)
        t += 15.minutes
      end

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_operator stats[:derived], :>=, 1

      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: day,
        end_on: day
      )
      assert_equal 1, points.size
      assert_in_delta 8.0, points.first[:v], 0.01
      assert_equal "derived", points.first[:s]
    end

    test "dual-writes postgres usgs daily instead of deriving" do
      day = Date.new(2026, 7, 8)
      DailyObservation.create!(time_series: @series, observed_on: day, value: 12.0, approval_status: "Approved")
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      96.times do
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 1.0)
        t += 15.minutes
      end

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_operator stats[:usgs_ensured], :>=, 1
      assert_equal 0, stats[:derived]

      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: day,
        end_on: day
      )
      assert_equal 1, points.size
      assert_in_delta 12.0, points.first[:v], 0.01
      assert_nil points.first[:s]
    end

    test "prune drains archived postgres daily when flag enabled" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      day = Date.current - 1
      DailyObservation.create!(time_series: @series, observed_on: day, value: 3.0)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => day.iso8601, "v" => 3.0, "s" => "usgs" } ]
      )

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_equal 1, stats[:daily_deleted]
      assert_nil DailyObservation.find_by(time_series_id: @series.id, observed_on: day)
    end

    test "alerts and prunes IV past retention when day never archived" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      # Older than 35-day retention relative to @as_of (2026-08-07).
      day = Date.new(2026, 6, 20)
      t = zone.local(day.year, day.month, day.day, 12, 0, 0)
      ContinuousObservation.create!(time_series: @series, observed_at: t, value: 2.0)

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_operator stats[:gaps_alerted], :>=, 1
      assert_operator stats[:iv_deleted], :>=, 1
      assert_equal 0, ContinuousObservation.where(time_series_id: @series.id).count
    end
  end
end
