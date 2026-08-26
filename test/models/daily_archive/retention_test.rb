require "test_helper"

module DailyArchive
  class RetentionTest < ActiveSupport::TestCase
    setup do
      @store = MemoryStore.new
      DailyArchive.store = @store
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      RetentionCheckpoint.clear!
      @location = create(:monitoring_location, time_zone: "PST", state_code: "wa")
      @series = create(:time_series, monitoring_location: @location)
      @as_of = Time.utc(2026, 8, 7, 12, 0, 0)
    end

    teardown do
      RetentionCheckpoint.clear!
      Rails.cache = @previous_cache
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

    test "does not drain official USGS leftover while archive upgrade is lock-busy" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      day = Date.new(2026, 7, 8)
      DailyObservation.create!(time_series: @series, observed_on: day, value: 12.0)
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      96.times do
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 8.0)
        t += 15.minutes
      end
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => day.iso8601, "v" => 8.0, "s" => "derived" } ]
      )
      Rails.cache.write(
        "#{Writer::LOCK_PREFIX}#{@series.id}:#{day.year}",
        true,
        expires_in: Writer::LOCK_TTL
      )

      stats = Retention.new(
        store: @store,
        writer: Writer.new(store: @store, lock_wait: 0),
        as_of: @as_of,
        client: nil
      ).perform

      assert_operator stats[:retrying], :>=, 1
      leftover = DailyObservation.find_by!(time_series_id: @series.id, observed_on: day)
      assert_in_delta 12.0, leftover.value, 0.01
      points = Reader.new(store: @store).points_for(
        time_series_id: @series.id,
        start_on: day,
        end_on: day
      )
      assert_equal 1, points.size
      assert_in_delta 8.0, points.first[:v], 0.01
      assert_equal "derived", points.first[:s]
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

    test "logs candidate counts and phase progress" do
      ENV["DAILY_ARCHIVE_PRUNE"] = "1"
      day = Date.current - 1
      DailyObservation.create!(time_series: @series, observed_on: day, value: 3.0)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => day.iso8601, "v" => 3.0, "s" => "usgs" } ]
      )

      io = StringIO.new
      progress = SyncProgress.new("RetentionTest", io: io, logger: nil, every: 1)
      Retention.new(store: @store, as_of: @as_of, client: nil, progress: progress).perform

      output = io.string
      assert_match(/starting retention handoff \+ postgres prune/, output)
      assert_match(/iv prune series=/, output)
      assert_match(/daily prune series=/, output)
      assert_match(/daily prune done deleted=1/, output)
    end

    test "prunes archived IV by local day without leaving tip rows" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      # Older than 35-day retention relative to @as_of (2026-08-07).
      old_day = Date.new(2026, 6, 20)
      tip_day = Date.new(2026, 8, 1)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => old_day.iso8601, "v" => 4.0, "s" => "usgs" } ]
      )

      old_t = zone.local(old_day.year, old_day.month, old_day.day, 0, 0, 0)
      4.times do
        ContinuousObservation.create!(time_series: @series, observed_at: old_t, value: 4.0)
        old_t += 15.minutes
      end
      tip_t = zone.local(tip_day.year, tip_day.month, tip_day.day, 12, 0, 0)
      ContinuousObservation.create!(time_series: @series, observed_at: tip_t, value: 5.0)

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_equal 4, stats[:iv_deleted]
      assert_equal 0, stats[:iv_prune_blocked]
      assert_equal 1, ContinuousObservation.where(time_series_id: @series.id).count
      assert_equal tip_t, ContinuousObservation.find_by!(time_series_id: @series.id).observed_at
    end

    test "blocks IV prune for unarchived cutoff-day rows still inside retry window" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      # Retention cutoff is 2026-07-03 12:00 UTC. Local July 3 morning points are
      # older than cutoff but the local calendar day is not yet past_retry_window?
      # (day < cutoff.to_date). Coverage is too thin to derive, so prune blocks.
      day = Date.new(2026, 7, 3)
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      3.times do
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 1.0)
        t += 15.minutes
      end

      stats = Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_equal 0, stats[:derived]
      assert_equal 0, stats[:iv_deleted]
      assert_equal 3, stats[:iv_prune_blocked]
      assert_equal 3, ContinuousObservation.where(time_series_id: @series.id).count
    end

    test "counts lock-busy archive writes as retrying without aborting prune" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      day = Date.new(2026, 7, 8)
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      96.times do
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 8.0)
        t += 15.minutes
      end

      lock_key = "#{Writer::LOCK_PREFIX}#{@series.id}:#{day.year}"
      Rails.cache.write(lock_key, true, expires_in: 1.minute)
      writer = Writer.new(store: @store, sleeper: ->(_seconds) { }, lock_wait: 0.05.seconds)

      stats = Retention.new(store: @store, writer: writer, as_of: @as_of, client: nil).perform
      assert_operator stats[:retrying], :>=, 1
      assert_equal 0, stats[:derived]
      assert_nil DailyArchiveShard.find_by(time_series_id: @series.id, year: day.year)
    end

    test "clears checkpoint after a successful full retention pass" do
      Retention.new(store: @store, as_of: @as_of, client: nil).perform
      assert_nil RetentionCheckpoint.read_raw
    end

    test "batches multi-day handoff into one year-shard write" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      days = [ Date.new(2026, 7, 6), Date.new(2026, 7, 7), Date.new(2026, 7, 8) ]
      days.each do |day|
        t = zone.local(day.year, day.month, day.day, 0, 0, 0)
        96.times do
          ContinuousObservation.create!(time_series: @series, observed_at: t, value: 8.0)
          t += 15.minutes
        end
      end

      put_count = 0
      store = @store
      store.define_singleton_method(:put) do |key, body, **kwargs|
        put_count += 1
        @objects[key] = body.to_s.b
        :put
      end

      stats = Retention.new(store: store, as_of: @as_of, client: nil).perform
      assert_equal 3, stats[:derived]
      assert_equal 1, put_count, "expected one R2 put for the 2026 year shard, got #{put_count}"

      points = Reader.new(store: store).points_for(
        time_series_id: @series.id,
        start_on: days.first,
        end_on: days.last
      )
      assert_equal 3, points.size
    end

    test "skips already-archived days without rewriting the year shard" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      day = Date.new(2026, 7, 8)
      Writer.new(store: @store).upsert(
        time_series_id: @series.id,
        points: [ { "d" => day.iso8601, "v" => 9.0, "s" => "usgs" } ]
      )
      t = zone.local(day.year, day.month, day.day, 0, 0, 0)
      96.times do
        ContinuousObservation.create!(time_series: @series, observed_at: t, value: 1.0)
        t += 15.minutes
      end

      put_count = 0
      store = @store
      store.define_singleton_method(:put) do |key, body, **kwargs|
        put_count += 1
        @objects[key] = body.to_s.b
        :put
      end

      stats = Retention.new(store: store, as_of: @as_of, client: nil).perform
      assert_operator stats[:usgs_ensured], :>=, 1
      assert_equal 0, stats[:derived]
      assert_equal 0, put_count
    end

    test "resumes iv prune after the last completed series without redoing it" do
      zone = ActiveSupport::TimeZone["America/Los_Angeles"]
      old_day = Date.new(2026, 6, 20)
      location_b = create(:monitoring_location, time_zone: "PST", state_code: "wa")
      series_b = create(:time_series, monitoring_location: location_b)
      first, second = [ @series, series_b ].sort_by(&:id)

      [ first, second ].each do |series|
        Writer.new(store: @store).upsert(
          time_series_id: series.id,
          points: [ { "d" => old_day.iso8601, "v" => 4.0, "s" => "usgs" } ]
        )
        ContinuousObservation.create!(
          time_series: series,
          observed_at: zone.local(old_day.year, old_day.month, old_day.day, 12, 0, 0),
          value: 4.0
        )
      end

      # Simulate cancel after handoff + first series IV prune completed.
      ContinuousObservation.where(time_series_id: first.id).delete_all
      checkpoint = RetentionCheckpoint.start!(@as_of)
      checkpoint.complete_phase!("handoff", usgs_ensured: 2, derived: 0, retrying: 0)
      checkpoint.mark_orphans_done!
      checkpoint.mark_series!(first.id, iv_deleted: 1)

      io = StringIO.new
      progress = SyncProgress.new("RetentionResume", io: io, logger: nil, every: 1)
      stats = Retention.new(store: @store, as_of: @as_of, client: nil, progress: progress).perform

      assert_match(/resuming retention phase=iv_prune after_series_id=#{first.id}/, io.string)
      assert_match(/handoff skipped: already completed/, io.string)
      # Cumulative across the canceled run + resume (1 already pruned + 1 now).
      assert_equal 2, stats[:iv_deleted]
      assert_equal 0, ContinuousObservation.where(time_series_id: second.id).count
      assert_nil RetentionCheckpoint.read_raw
    end
  end
end
