module DailyArchive
  # USGS-first day-31+ handoff into R2, then safe IV / scratch-daily prune.
  #
  # Invariant: never prune IV for local day D until R2 has D (usgs or derived)
  # or D is an explicit alerted gap.
  class Retention
    def initialize(store: DailyArchive.store, writer: nil, as_of: Time.current, client: nil)
      @store = store
      @writer = writer || Writer.new(store: store)
      @as_of = as_of
      @client = client
      @gap_days = Set.new # [time_series_id, iso_day] alerted this run
    end

    def perform
      handoff = ensure_aged_days!
      iv_result = prune_continuous!
      daily_result = prune_daily!

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
      return { usgs_ensured: 0, derived: 0, retrying: 0 } unless @store.enabled?

      frontier = DailyArchive::CONTINUOUS_ROLLUP_AFTER.ago(@as_of)
      series_ids = ContinuousObservation
        .where("observed_at < ?", frontier)
        .distinct
        .pluck(:time_series_id)

      TimeSeries.where(id: series_ids).includes(:monitoring_location).find_each do |series|
        aged_local_days(series, frontier).each do |day|
          case ensure_day!(series, day)
          when :usgs then usgs_ensured += 1
          when :derived then derived += 1
          when :retrying then retrying += 1
          end
        end
      end

      { usgs_ensured: usgs_ensured, derived: derived, retrying: retrying }
    end

    def aged_local_days(series, frontier)
      zone = local_zone(series.monitoring_location)
      ContinuousObservation
        .where(time_series_id: series.id)
        .where("observed_at < ?", frontier)
        .pluck(:observed_at)
        .map { |t| t.in_time_zone(zone).to_date }
        .uniq
        .sort
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

        DailyObservation.upsert(
          {
            time_series_id: series.id,
            observed_on: day,
            value: item["value"],
            approval_status: item["approval_status"],
            qualifier: item["qualifier"],
            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: %i[time_series_id observed_on]
        )
        @writer.upsert(
          time_series_id: series.id,
          points: [ {
            "d" => day.iso8601,
            "v" => item["value"].to_f,
            "s" => DailyArchive::SOURCE_USGS,
            "a" => item["approval_status"]
          } ]
        )
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
      gaps_alerted = 0
      blocked = 0
      deletable_ids = []
      series_cache = {}

      ContinuousObservation
        .where("observed_at < ?", cutoff)
        .select(:id, :time_series_id, :observed_at)
        .find_each do |row|
          series = series_cache[row.time_series_id] ||=
            TimeSeries.includes(:monitoring_location).find_by(id: row.time_series_id)
          unless series
            deletable_ids << row.id
            next
          end

          day = row.observed_at.in_time_zone(local_zone(series.monitoring_location)).to_date
          if archived_day?(series.id, day) || gap_alerted?(series.id, day)
            deletable_ids << row.id
          elsif past_retry_window?(day)
            alert_gap!(series, day)
            deletable_ids << row.id
          else
            blocked += 1
          end
        end

      gaps_alerted = @gap_days.size

      deleted = 0
      deletable_ids.each_slice(1_000) do |ids|
        deleted += ContinuousObservation.where(id: ids).delete_all
      end
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
        cutoff = DailyArchive.hot_cutoff_on
        deletable_ids = []
        blocked = 0
        day_cache = {}

        DailyObservation.where("observed_on < ?", cutoff).select(:id, :time_series_id, :observed_on).find_each do |row|
          cache_key = [ row.time_series_id, row.observed_on.year ]
          archived_days = day_cache[cache_key] ||= archived_days_for(row.time_series_id, row.observed_on.year)
          if archived_days.include?(row.observed_on.iso8601)
            deletable_ids << row.id
          else
            blocked += 1
          end
        end

        deleted = 0
        deletable_ids.each_slice(1_000) do |ids|
          deleted += DailyObservation.where(id: ids).delete_all
        end
        { deleted: deleted, blocked: blocked }
      else
        deleted = DailyObservation.where(
          "observed_on < ?", HistoryIngestion::DAILY_RETENTION.ago(@as_of).to_date
        ).delete_all
        { deleted: deleted, blocked: 0 }
      end
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
