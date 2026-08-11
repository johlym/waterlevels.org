module DailyArchive
  # USGS-first day-31+ handoff into R2, then safe IV prune and Postgres daily drain.
  #
  # Invariant: never prune IV for local day D until R2 has D (usgs or derived)
  # or D is an explicit alerted gap.
  #
  # IV/daily GC is day-oriented: decide per (series, local day), then DELETE by
  # indexed time/date ranges. Avoids scanning every tip row into a giant Ruby
  # id list on large fleets.
  #
  # Progress is checkpointed per series so a canceled/retried job on the same
  # UTC day resumes instead of redoing completed handoff/prune work.
  #
  # Handoff batches archive writes per series (Writer groups by year) so a
  # multi-day backlog does one R2 read-modify-write per year shard instead of
  # one per local day. Year shards are cached in-process for presence/source
  # checks to avoid repeated get/decode.
  class Retention
    def initialize(store: DailyArchive.store, writer: nil, as_of: Time.current, client: nil, progress: nil, checkpoint: nil)
      @store = store
      @writer = writer || Writer.new(store: store)
      @as_of = as_of
      @client = client
      @progress = progress
      @checkpoint = checkpoint
      @gap_days = Set.new # [time_series_id, iso_day] alerted this run
      @archived_points_cache = {}
    end

    def perform
      @checkpoint ||= RetentionCheckpoint.resume_or_start!(as_of: @as_of)
      @as_of = @checkpoint.as_of
      @gap_days = Set.new(@checkpoint.gap_days)

      if @checkpoint.resumed
        @progress&.step(
          "resuming retention phase=#{@checkpoint.phase} " \
          "after_series_id=#{@checkpoint.after_series_id} as_of=#{@as_of.utc.iso8601}"
        )
      else
        @progress&.step("starting retention handoff + postgres prune as_of=#{@as_of.utc.iso8601}")
      end

      handoff = ensure_aged_days!
      @progress&.step(
        "handoff done usgs_ensured=#{handoff[:usgs_ensured]} " \
        "derived=#{handoff[:derived]} retrying=#{handoff[:retrying]}"
      )

      iv_result = prune_continuous!
      @progress&.step(
        "iv prune done deleted=#{iv_result[:deleted]} " \
        "blocked=#{iv_result[:blocked]} gaps_alerted=#{iv_result[:gaps_alerted]}"
      )

      daily_result = prune_daily!
      @progress&.step(
        "daily prune done deleted=#{daily_result[:deleted]} blocked=#{daily_result[:blocked]}"
      )

      @checkpoint.clear!

      {
        usgs_ensured: handoff[:usgs_ensured],
        derived: handoff[:derived],
        retrying: handoff[:retrying],
        gaps_alerted: iv_result[:gaps_alerted],
        iv_deleted: iv_result[:deleted],
        iv_prune_blocked: iv_result[:blocked],
        daily_deleted: daily_result[:deleted],
        daily_prune_blocked: daily_result[:blocked],
        # Back-compat aliases for existing job/admin wiring.
        rolled_up: handoff[:derived],
        rollup_skipped: handoff[:usgs_ensured] + handoff[:retrying],
        continuous_deleted: iv_result[:deleted]
      }
    end

    private

    def ensure_aged_days!
      if @checkpoint.phase_completed?("handoff")
        stats = @checkpoint.stats
        @progress&.step(
          "handoff skipped: already completed usgs_ensured=#{stats["usgs_ensured"]} " \
          "derived=#{stats["derived"]} retrying=#{stats["retrying"]}"
        )
        return {
          usgs_ensured: stats["usgs_ensured"],
          derived: stats["derived"],
          retrying: stats["retrying"]
        }
      end

      usgs_ensured = @checkpoint.stats["usgs_ensured"]
      derived = @checkpoint.stats["derived"]
      retrying = @checkpoint.stats["retrying"]
      unless @store.enabled?
        @progress&.step("handoff skipped: archive store disabled")
        @checkpoint.complete_phase!(
          "handoff",
          usgs_ensured: 0,
          derived: 0,
          retrying: 0
        )
        return { usgs_ensured: 0, derived: 0, retrying: 0 }
      end

      frontier = DailyArchive::CONTINUOUS_ROLLUP_AFTER.ago(@as_of)
      series_ids = ContinuousObservation
        .where("observed_at < ?", frontier)
        .distinct
        .pluck(:time_series_id)
      total_series = series_ids.size
      @progress&.step(
        "handoff series=#{total_series} frontier=#{frontier.utc.iso8601} " \
        "after_series_id=#{@checkpoint.after_series_id}"
      )

      processed = 0
      scope = @checkpoint.series_scope(
        TimeSeries.where(id: series_ids).includes(:monitoring_location)
      )
      scope.find_each do |series|
        counts = ensure_series_days!(series, aged_local_days(series, frontier))
        usgs_ensured += counts[:usgs_ensured]
        derived += counts[:derived]
        retrying += counts[:retrying]
        @checkpoint.mark_series!(
          series.id,
          usgs_ensured: counts[:usgs_ensured],
          derived: counts[:derived],
          retrying: counts[:retrying]
        )
        processed += 1
        if (processed % 50).zero?
          @progress&.step(
            "handoff series_done=#{processed} remaining_cursor=#{series.id} " \
            "usgs_ensured=#{usgs_ensured} derived=#{derived} retrying=#{retrying}"
          )
        end
      end

      @checkpoint.complete_phase!(
        "handoff",
        usgs_ensured: usgs_ensured,
        derived: derived,
        retrying: retrying
      )
      { usgs_ensured: usgs_ensured, derived: derived, retrying: retrying }
    end

    def aged_local_days(series, frontier)
      zone = local_zone(series.monitoring_location)
      tz = postgres_time_zone_name(zone)
      ContinuousObservation
        .where(time_series_id: series.id)
        .where("observed_at < ?", frontier)
        .distinct
        .order(Arel.sql("1"))
        .pluck(Arel.sql(local_date_sql(tz)))
        .map { |day| day.is_a?(Date) ? day : Date.parse(day.to_s) }
    end

    # Ensure every aged local day for one series, buffering archive writes so
    # each year shard is rewritten at most once for the backlog.
    def ensure_series_days!(series, days)
      return { usgs_ensured: 0, derived: 0, retrying: 0 } if days.empty?

      usgs_ensured = 0
      derived = 0
      retrying = 0
      pending = [] # { point:, kind: :usgs|:derived }

      postgres_by_day = postgres_usgs_dailies_by_day(series, days)
      missing_days = []

      days.each do |day|
        if archived_day?(series.id, day)
          if postgres_by_day[day] && !archived_usgs_day?(series.id, day)
            pending << { point: postgres_point(postgres_by_day[day]), kind: :usgs }
          elsif archived_usgs_day?(series.id, day)
            usgs_ensured += 1
          end
          # Already-archived derived days are :present — no counter bump.
          next
        end

        if (row = postgres_by_day[day])
          pending << { point: postgres_point(row), kind: :usgs }
          next
        end

        missing_days << day
      end

      usgs_by_day = fetch_usgs_dailies_for_days!(series, missing_days)
      missing_days.each do |day|
        if (point = usgs_by_day[day])
          pending << { point: point, kind: :usgs }
          next
        end

        point = UsgsLikeDailyMean.new(time_series: series, day: day).compute
        if point
          pending << { point: point, kind: :derived }
        else
          retrying += 1
        end
      end

      if pending.any?
        begin
          @writer.upsert(
            time_series_id: series.id,
            points: pending.map { |entry| entry[:point] }
          )
          invalidate_archive_cache!(series.id, pending.map { |entry| entry[:point] })
          pending.each do |entry|
            case entry[:kind]
            when :usgs then usgs_ensured += 1
            when :derived then derived += 1
            end
          end
        rescue Writer::LockBusyError => e
          Rails.logger.warn(
            "[DailyArchive::Retention] archive write lock busy series=#{series.id} " \
            "pending_days=#{pending.size}: #{e.message}"
          )
          retrying += pending.size
        end
      end

      { usgs_ensured: usgs_ensured, derived: derived, retrying: retrying }
    end

    def postgres_usgs_dailies_by_day(series, days)
      series.daily_observations
        .where(observed_on: days)
        .where("qualifier IS NULL OR qualifier != ?", "derived_continuous")
        .index_by(&:observed_on)
    end

    def postgres_point(row)
      {
        "d" => row.observed_on.iso8601,
        "v" => row.value.to_f,
        "s" => DailyArchive::SOURCE_USGS,
        "a" => row.approval_status
      }
    end

    # One USGS daily request per year span covering missing days (not per day).
    def fetch_usgs_dailies_for_days!(series, days)
      return {} if days.empty?

      client = usgs_client
      return {} if client.nil?
      return {} if Usgs::RateLimitCircuit.open?(client.circuit_key)

      wanted = days.to_set
      found = {}
      location = series.monitoring_location

      days.group_by(&:year).each_value do |year_days|
        start_day = year_days.min
        end_day = year_days.max
        begin
          client.each_collection_item(
            "daily",
            monitoring_location_id: location.usgs_monitoring_location_id,
            parameter_code: series.parameter_code,
            datetime: "#{start_day.iso8601}/#{end_day.iso8601}"
          ) do |item|
            item_day = Date.parse(item["time"] || item["date"] || item["datetime"].to_s) rescue nil
            next unless item_day && wanted.include?(item_day)
            next if item["value"].blank?

            found[item_day] = {
              "d" => item_day.iso8601,
              "v" => item["value"].to_f,
              "s" => DailyArchive::SOURCE_USGS,
              "a" => item["approval_status"]
            }
          end
        rescue Usgs::Client::Error, Usgs::Client::RateLimitError => e
          Rails.logger.warn(
            "[DailyArchive::Retention] USGS daily fetch failed series=#{series.id} " \
            "range=#{start_day}/#{end_day}: #{e.message}"
          )
        end
      end

      found
    end

    def usgs_client
      return @client if @client
      return nil if Rails.env.test?

      @client = Usgs::Client.for_history(:daily)
    rescue StandardError
      nil
    end

    def prune_continuous!
      if @checkpoint.phase_completed?("iv_prune")
        stats = @checkpoint.stats
        @progress&.step(
          "iv prune skipped: already completed deleted=#{stats["iv_deleted"]} " \
          "blocked=#{stats["iv_blocked"]} gaps_alerted=#{@gap_days.size}"
        )
        return {
          deleted: stats["iv_deleted"],
          blocked: stats["iv_blocked"],
          gaps_alerted: @gap_days.size
        }
      end

      cutoff = HistoryIngestion.continuous_retention.ago(@as_of)
      blocked = @checkpoint.stats["iv_blocked"]
      deleted = @checkpoint.stats["iv_deleted"]

      # Orphans only need one pass; skip when resuming after that work landed.
      unless @checkpoint.orphans_done?
        orphan_scope = ContinuousObservation
          .where("observed_at < ?", cutoff)
          .where.not(time_series_id: TimeSeries.select(:id))
        orphan_count = orphan_scope.count
        if orphan_count.positive?
          @progress&.step("iv prune deleting orphan rows=#{orphan_count}")
          deleted += orphan_scope.delete_all
        end
        @checkpoint.mark_orphans_done!(iv_deleted: orphan_count)
      end

      series_ids = ContinuousObservation
        .where("observed_at < ?", cutoff)
        .distinct
        .pluck(:time_series_id)
      total_series = series_ids.size
      @progress&.step(
        "iv prune series=#{total_series} cutoff=#{cutoff.utc.iso8601} " \
        "after_series_id=#{@checkpoint.after_series_id} (day-oriented GC)"
      )

      processed = 0
      scope = @checkpoint.series_scope(
        TimeSeries.where(id: series_ids).includes(:monitoring_location)
      )
      scope.find_each do |series|
        zone = local_zone(series.monitoring_location)
        series_deleted = 0
        series_blocked = 0
        aged_local_days(series, cutoff).each do |day|
          day_scope = continuous_day_scope(series.id, zone, day, before: cutoff)
          if archived_day?(series.id, day) || gap_alerted?(series.id, day)
            series_deleted += day_scope.delete_all
          elsif past_retry_window?(day)
            alert_gap!(series, day)
            series_deleted += day_scope.delete_all
          else
            series_blocked += day_scope.count
          end
        end
        deleted += series_deleted
        blocked += series_blocked
        # Prune removes aged IV (near the 32d anchor) — refresh tip/prev/anchor denorm.
        TimeSeries.refresh_continuous_coverage!([ series.id ], as_of: @as_of) if series_deleted.positive?
        @checkpoint.mark_series!(
          series.id,
          iv_deleted: series_deleted,
          iv_blocked: series_blocked
        )

        processed += 1
        if (processed % 50).zero?
          @progress&.step(
            "iv prune series_done=#{processed} remaining_cursor=#{series.id} " \
            "deleted=#{deleted} blocked=#{blocked} gaps_alerted=#{@gap_days.size}"
          )
        end
      end

      gaps_alerted = @gap_days.size
      @checkpoint.complete_phase!(
        "iv_prune",
        iv_deleted: deleted,
        iv_blocked: blocked
      )
      @progress&.step(
        "iv prune complete deleted=#{deleted} blocked=#{blocked} gaps_alerted=#{gaps_alerted}"
      )
      { deleted: deleted, blocked: blocked, gaps_alerted: gaps_alerted }
    end

    def past_retry_window?(day)
      # Local calendar day whose end is older than continuous retention.
      day < HistoryIngestion.continuous_retention.ago(@as_of).to_date
    end

    def alert_gap!(series, day)
      key = [ series.id, day.iso8601 ]
      return if @gap_days.include?(key)

      @gap_days << key
      @checkpoint&.record_gap!(series.id, day.iso8601)
      message = "[DailyArchive::Retention] daily gap alerted series=#{series.id} site=#{series.monitoring_location.site_number} day=#{day}"
      Rails.logger.error(message)
      Sentry.capture_message(message, level: :warning) if defined?(Sentry)
      Telemetry.add_attributes("app.daily_gap_alerted" => 1) if defined?(Telemetry)
    end

    def gap_alerted?(time_series_id, day)
      @gap_days.include?([ time_series_id, day.iso8601 ])
    end

    def prune_daily!
      if @checkpoint.phase_completed?("daily_prune")
        stats = @checkpoint.stats
        return { deleted: stats["daily_deleted"], blocked: stats["daily_blocked"] }
      end

      if DailyArchive.prune_enabled?
        # Drain every Postgres daily that already exists in R2 — no scratch tip.
        # Work per series so we load each year shard once and delete by date list
        # instead of accumulating every row id in Ruby.
        blocked = @checkpoint.stats["daily_blocked"]
        deleted = @checkpoint.stats["daily_deleted"]
        series_ids = DailyObservation
          .distinct
          .where("time_series_id > ?", @checkpoint.after_series_id)
          .order(:time_series_id)
          .pluck(:time_series_id)
        total_series = series_ids.size
        @progress&.step(
          "daily prune series=#{total_series} after_series_id=#{@checkpoint.after_series_id} " \
          "(R2 drain mode; day-oriented GC)"
        )

        processed = 0
        series_ids.each do |time_series_id|
          series_deleted = 0
          series_blocked = 0
          days_by_year = DailyObservation
            .where(time_series_id: time_series_id)
            .pluck(:observed_on)
            .group_by(&:year)

          days_by_year.each do |year, days|
            archived_days = archived_days_for(time_series_id, year)
            deletable_days = days.select { |day| archived_days.include?(day.iso8601) }
            series_blocked += days.size - deletable_days.size
            next if deletable_days.empty?

            series_deleted += DailyObservation
              .where(time_series_id: time_series_id, observed_on: deletable_days)
              .delete_all
          end

          deleted += series_deleted
          blocked += series_blocked
          @checkpoint.mark_series!(
            time_series_id,
            daily_deleted: series_deleted,
            daily_blocked: series_blocked
          )

          processed += 1
          if (processed % 50).zero? || processed == total_series
            @progress&.step(
              "daily prune series=#{processed}/#{total_series} " \
              "deleted=#{deleted} blocked=#{blocked}"
            )
          end
        end

        @checkpoint.complete_phase!(
          "daily_prune",
          daily_deleted: deleted,
          daily_blocked: blocked
        )
        @progress&.step("daily prune complete deleted=#{deleted} blocked=#{blocked}")
        { deleted: deleted, blocked: blocked }
      else
        cutoff_day = HistoryIngestion::DAILY_RETENTION.ago(@as_of).to_date
        candidate_count = DailyObservation.where("observed_on < ?", cutoff_day).count
        @progress&.step(
          "daily prune age-cutoff mode candidates=#{candidate_count} cutoff_day=#{cutoff_day}"
        )
        deleted = DailyObservation.where("observed_on < ?", cutoff_day).delete_all
        @checkpoint.complete_phase!(
          "daily_prune",
          daily_deleted: deleted,
          daily_blocked: 0
        )
        @progress&.step("daily prune age-cutoff deleted=#{deleted}")
        { deleted: deleted, blocked: 0 }
      end
    end

    def continuous_day_scope(time_series_id, zone, day, before:)
      day_start = zone.local(day.year, day.month, day.day)
      day_end = day_start + 1.day
      ContinuousObservation
        .where(time_series_id: time_series_id)
        .where("observed_at >= ? AND observed_at < ?", day_start, day_end)
        .where("observed_at < ?", before)
    end

    def local_date_sql(tz)
      quoted = ActiveRecord::Base.connection.quote(tz)
      "((observed_at AT TIME ZONE 'UTC') AT TIME ZONE #{quoted})::date"
    end

    def postgres_time_zone_name(zone)
      zone.tzinfo&.name.presence || zone.name
    end

    def archived_day?(time_series_id, day)
      archived_points_for(time_series_id, day.year).key?(day.iso8601)
    end

    def archived_usgs_day?(time_series_id, day)
      point = archived_points_for(time_series_id, day.year)[day.iso8601]
      point.present? && point["s"] == DailyArchive::SOURCE_USGS
    end

    def archived_days_for(time_series_id, year)
      archived_points_for(time_series_id, year).keys.to_set
    end

    # Decode each year shard once per retention run; presence + source checks
    # share this map so handoff does not re-get R2 for every local day.
    def archived_points_for(time_series_id, year)
      cache_key = [ time_series_id, year ]
      @archived_points_cache[cache_key] ||= begin
        key = DailyArchive.object_key(time_series_id, year)
        Codec.decode(@store.get(key)).index_by { |p| p["d"] }
      end
    end

    def invalidate_archive_cache!(time_series_id, points)
      years = points.filter_map { |point| Date.parse(point["d"]).year rescue nil }.uniq
      years.each { |year| @archived_points_cache.delete([ time_series_id, year ]) }
    end

    def local_zone(location)
      Usgs::TimeZones.resolve(location.time_zone, state_code: location.state_code) || Time.zone
    end
  end
end
