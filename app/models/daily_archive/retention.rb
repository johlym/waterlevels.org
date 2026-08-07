module DailyArchive
  # Rollup day-31 continuous → derived daily archive, then prune IV / hot daily.
  class Retention
    def initialize(store: DailyArchive.store, writer: nil, as_of: Time.current)
      @store = store
      @writer = writer || Writer.new(store: store)
      @as_of = as_of
    end

    def perform
      rollup_stats = rollup_aged_continuous!
      continuous_deleted = prune_continuous!
      daily_result = prune_daily!

      {
        rolled_up: rollup_stats[:rolled_up],
        rollup_skipped: rollup_stats[:skipped],
        continuous_deleted: continuous_deleted,
        daily_deleted: daily_result[:deleted],
        daily_prune_blocked: daily_result[:blocked]
      }
    end

    private

    def rollup_aged_continuous!
      rolled_up = 0
      skipped = 0
      return { rolled_up: 0, skipped: 0 } unless @store.enabled?

      frontier = DailyArchive::CONTINUOUS_ROLLUP_AFTER.ago(@as_of)
      series_ids = ContinuousObservation
        .where("observed_at < ?", frontier)
        .distinct
        .pluck(:time_series_id)

      TimeSeries.where(id: series_ids).includes(:monitoring_location).find_each do |series|
        day = UsgsLikeDailyMean.rollup_day_for(series.monitoring_location, as_of: @as_of)
        next if day.blank?

        if official_daily?(series, day)
          skipped += 1
          next
        end

        point = UsgsLikeDailyMean.new(time_series: series, day: day).compute
        if point.nil?
          skipped += 1
          next
        end

        @writer.upsert(time_series_id: series.id, points: [ point ])
        unless DailyArchive.cold?(day)
          DailyObservation.upsert(
            {
              time_series_id: series.id,
              observed_on: day,
              value: point["v"],
              approval_status: nil,
              qualifier: "derived_continuous",
              created_at: Time.current,
              updated_at: Time.current
            },
            unique_by: %i[time_series_id observed_on]
          )
        end
        rolled_up += 1
      end

      { rolled_up: rolled_up, skipped: skipped }
    end

    def official_daily?(series, day)
      row = series.daily_observations.find_by(observed_on: day)
      return true if row && row.qualifier != "derived_continuous"

      key = DailyArchive.object_key(series.id, day.year)
      Codec.decode(@store.get(key)).any? do |p|
        p["d"] == day.iso8601 && p["s"] == DailyArchive::SOURCE_USGS
      end
    end

    def prune_continuous!
      ContinuousObservation.where(
        "observed_at < ?", HistoryIngestion::CONTINUOUS_RETENTION.ago(@as_of)
      ).delete_all
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

    def archived_days_for(time_series_id, year)
      key = DailyArchive.object_key(time_series_id, year)
      Codec.decode(@store.get(key)).to_set { |p| p["d"] }
    end
  end
end
