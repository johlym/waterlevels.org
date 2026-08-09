module DailyArchive
  # USGS-first day-31+ handoff into R2, then safe IV prune and Postgres daily drain.
  #
  # Invariant: never prune IV for local day D until R2 has D (usgs or derived)
  # or D is an explicit alerted gap.
  #
  # IV/daily GC is day-oriented: decide per (series, local day), then DELETE by
  # indexed time/date ranges. Avoids scanning every tip row into a giant Ruby
  # id list on large fleets.
  class Retention
    def initialize(store: DailyArchive.store, writer: nil, as_of: Time.current, client: nil, progress: nil)
      @store = store
      @writer = writer || Writer.new(store: store)
      @as_of = as_of
      @client = client
      @progress = progress
      @gap_days = Set.new # [time_series_id, iso_day] alerted this run
    end

    def perform
      @progress&.step("starting retention handoff + postgres prune")
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
      usgs_ensured = 0
      derived = 0
      retrying = 0
      unless @store.enabled?
        @progress&.step("handoff skipped: archive store disabled")
        return { usgs_ensured: 0, derived: 0, retrying: 0 }
      end

      frontier = DailyArchive::CONTINUOUS_ROLLUP_AFTER.ago(@as_of)
      series_ids = ContinuousObservation
        .where("observed_at < ?", frontier)
        .distinct
        .pluck(:time_series_id)
      total_series = series_ids.size
      @progress&.step("handoff series=#{total_series} frontier=#{frontier.utc.iso8601}")

      processed = 0
      TimeSeries.where(id: series_ids).includes(:monitoring_location).find_each do |series|
        aged_local_days(series, frontier).each do |day|
          case ensure_day!(series, day)
          when :usgs then usgs_ensured += 1
          when :derived then derived += 1
          when :retrying then retrying += 1
          end
        end
        processed += 1
        if (processed % 50).zero? || processed == total_series
          @progress&.step(
            "handoff series=#{processed}/#{total_series} " \
            "usgs_ensured=#{usgs_ensured} derived=#{derived} retrying=#{retrying}"
          )
        end
      end

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

    def ensure_day!(series, day)
      if archived_day?(series.id, day)
        if postgres_usgs_daily?(series, day) && !archived_usgs_day?(series.id, day)
          dual_write_postgres_day!(series, day)
          return :usgs
        end
        return archived_usgs_day?(series.id, day) ? :usgs : :present
      end

      if postgres_usgs_daily?(series, day)
        dual_write_postgres_day!(series, day)
        return :usgs
      end

      if fetch_and_store_usgs_daily!(series, day)
        return :usgs
      end

      point = UsgsLikeDailyMean.new(time_series: series, day: day).compute
      if point
        @writer.upsert(time_series_id: series.id, points: [ point ])
        # Invalidate day cache so prune sees the new point.
        @archived_days_cache&.delete([ series.id, day.year ])
        return :derived
      end

      :retrying
    rescue Writer::LockBusyError => e
      # Concurrent export/backfill holds the year shard; leave IV in place for a later run.
      Rails.logger.warn(
        "[DailyArchive::Retention] archive write lock busy series=#{series.id} day=#{day}: #{e.message}"
      )
      :retrying
    end

    def postgres_usgs_daily?(series, day)
      row = series.daily_observations.find_by(observed_on: day)
      row.present? && row.qualifier != "derived_continuous"
    end

    def dual_write_postgres_day!(series, day)
      row = series.daily_observations.find_by(observed_on: day)
      return if row.blank?

      @writer.upsert(
        time_series_id: series.id,
        points: [ {
          "d" => day.iso8601,
          "v" => row.value.to_f,
          "s" => DailyArchive::SOURCE_USGS,
          "a" => row.approval_status
        } ]
      )
      @archived_days_cache&.delete([ series.id, day.year ])
    end

    def fetch_and_store_usgs_daily!(series, day)
      client = usgs_client
      return false if client.nil?
      return false if Usgs::RateLimitCircuit.open?(client.circuit_key)

      location = series.monitoring_location
      found = false
      client.each_collection_item(
        "daily",
        monitoring_location_id: location.usgs_monitoring_location_id,
        parameter_code: series.parameter_code,
        datetime: "#{day.iso8601}/#{day.iso8601}"
      ) do |item|
        item_day = Date.parse(item["time"] || item["date"] || item["datetime"].to_s) rescue nil
        next unless item_day == day
        next if item["value"].blank?

        @writer.upsert(
          time_series_id: series.id,
          points: [ {
            "d" => day.iso8601,
            "v" => item["value"].to_f,
            "s" => DailyArchive::SOURCE_USGS,
            "a" => item["approval_status"]
          } ]
        )
        @archived_days_cache&.delete([ series.id, day.year ])
        found = true
      end
      found
    rescue Usgs::Client::Error, Usgs::Client::RateLimitError => e
      Rails.logger.warn("[DailyArchive::Retention] USGS daily fetch failed series=#{series.id} day=#{day}: #{e.message}")
      false
    end

    def usgs_client
      return @client if @client
      return nil if Rails.env.test?

      @client = Usgs::Client.for_history
    rescue StandardError
      nil
    end

    def prune_continuous!
      cutoff = HistoryIngestion::CONTINUOUS_RETENTION.ago(@as_of)
      blocked = 0
      deleted = 0

      # Defensive: drop tip rows whose series is gone (FK normally prevents this).
      orphan_scope = ContinuousObservation
        .where("observed_at < ?", cutoff)
        .where.not(time_series_id: TimeSeries.select(:id))
      orphan_count = orphan_scope.count
      if orphan_count.positive?
        @progress&.step("iv prune deleting orphan rows=#{orphan_count}")
        deleted += orphan_scope.delete_all
      end

      series_ids = ContinuousObservation
        .where("observed_at < ?", cutoff)
        .distinct
        .pluck(:time_series_id)
      total_series = series_ids.size
      @progress&.step(
        "iv prune series=#{total_series} cutoff=#{cutoff.utc.iso8601} " \
        "(day-oriented GC; no per-row ID scan)"
      )

      processed = 0
      TimeSeries.where(id: series_ids).includes(:monitoring_location).find_each do |series|
        zone = local_zone(series.monitoring_location)
        aged_local_days(series, cutoff).each do |day|
          day_scope = continuous_day_scope(series.id, zone, day, before: cutoff)
          if archived_day?(series.id, day) || gap_alerted?(series.id, day)
            deleted += day_scope.delete_all
          elsif past_retry_window?(day)
            alert_gap!(series, day)
            deleted += day_scope.delete_all
          else
            blocked += day_scope.count
          end
        end

        processed += 1
        if (processed % 50).zero? || processed == total_series
          @progress&.step(
            "iv prune series=#{processed}/#{total_series} " \
            "deleted=#{deleted} blocked=#{blocked} gaps_alerted=#{@gap_days.size}"
          )
        end
      end

      gaps_alerted = @gap_days.size
      @progress&.step(
        "iv prune complete deleted=#{deleted} blocked=#{blocked} gaps_alerted=#{gaps_alerted}"
      )
      { deleted: deleted, blocked: blocked, gaps_alerted: gaps_alerted }
    end

    def past_retry_window?(day)
      # Local calendar day whose end is older than continuous retention.
      day < HistoryIngestion::CONTINUOUS_RETENTION.ago(@as_of).to_date
    end

    def alert_gap!(series, day)
      key = [ series.id, day.iso8601 ]
      return if @gap_days.include?(key)

      @gap_days << key
      message = "[DailyArchive::Retention] daily gap alerted series=#{series.id} site=#{series.monitoring_location.site_number} day=#{day}"
      Rails.logger.error(message)
      Sentry.capture_message(message, level: :warning) if defined?(Sentry)
      Telemetry.add_attributes("app.daily_gap_alerted" => 1) if defined?(Telemetry)
    end

    def gap_alerted?(time_series_id, day)
      @gap_days.include?([ time_series_id, day.iso8601 ])
    end

    def prune_daily!
      if DailyArchive.prune_enabled?
        # Drain every Postgres daily that already exists in R2 — no scratch tip.
        # Work per series so we load each year shard once and delete by date list
        # instead of accumulating every row id in Ruby.
        blocked = 0
        deleted = 0
        series_ids = DailyObservation.distinct.pluck(:time_series_id)
        total_series = series_ids.size
        @progress&.step(
          "daily prune series=#{total_series} (R2 drain mode; day-oriented GC)"
        )

        processed = 0
        series_ids.each do |time_series_id|
          days_by_year = DailyObservation
            .where(time_series_id: time_series_id)
            .pluck(:observed_on)
            .group_by(&:year)

          days_by_year.each do |year, days|
            archived_days = archived_days_for(time_series_id, year)
            deletable_days = days.select { |day| archived_days.include?(day.iso8601) }
            blocked += days.size - deletable_days.size
            next if deletable_days.empty?

            deleted += DailyObservation
              .where(time_series_id: time_series_id, observed_on: deletable_days)
              .delete_all
          end

          processed += 1
          if (processed % 50).zero? || processed == total_series
            @progress&.step(
              "daily prune series=#{processed}/#{total_series} " \
              "deleted=#{deleted} blocked=#{blocked}"
            )
          end
        end

        @progress&.step("daily prune complete deleted=#{deleted} blocked=#{blocked}")
        { deleted: deleted, blocked: blocked }
      else
        cutoff_day = HistoryIngestion::DAILY_RETENTION.ago(@as_of).to_date
        candidate_count = DailyObservation.where("observed_on < ?", cutoff_day).count
        @progress&.step(
          "daily prune age-cutoff mode candidates=#{candidate_count} cutoff_day=#{cutoff_day}"
        )
        deleted = DailyObservation.where("observed_on < ?", cutoff_day).delete_all
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
      archived_days_for(time_series_id, day.year).include?(day.iso8601)
    end

    def archived_usgs_day?(time_series_id, day)
      key = DailyArchive.object_key(time_series_id, day.year)
      Codec.decode(@store.get(key)).any? do |p|
        p["d"] == day.iso8601 && p["s"] == DailyArchive::SOURCE_USGS
      end
    end

    def archived_days_for(time_series_id, year)
      @archived_days_cache ||= {}
      cache_key = [ time_series_id, year ]
      @archived_days_cache[cache_key] ||= begin
        key = DailyArchive.object_key(time_series_id, year)
        Codec.decode(@store.get(key)).to_set { |p| p["d"] }
      end
    end

    def local_zone(location)
      Usgs::TimeZones.resolve(location.time_zone, state_code: location.state_code) || Time.zone
    end
  end
end
