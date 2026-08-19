module DailyArchive
  # Delete leftover Postgres daily_observations whose local day already exists
  # in the R2 (or local) year shard. Used by nightly retention, the periodic
  # drain job, and export-after-shuttle cleanup.
  class Drain
    def initialize(store: DailyArchive.store, progress: nil)
      @store = store
      @progress = progress
      @archived_points_cache = {}
    end

    def perform(after_series_id: 0)
      return { deleted: 0, blocked: 0 } unless DailyArchive.prune_enabled?

      deleted = 0
      blocked = 0
      series_ids = DailyObservation
        .distinct
        .where("time_series_id > ?", after_series_id)
        .order(:time_series_id)
        .pluck(:time_series_id)
      total_series = series_ids.size
      @progress&.step(
        "daily prune series=#{total_series} after_series_id=#{after_series_id} " \
        "(R2 drain mode; day-oriented GC)"
      )

      series_ids.each_with_index do |time_series_id, index|
        counts = drain_series!(time_series_id)
        deleted += counts[:deleted]
        blocked += counts[:blocked]
        yield(time_series_id, counts) if block_given?

        processed = index + 1
        if (processed % 50).zero? || processed == total_series
          @progress&.step(
            "daily prune series=#{processed}/#{total_series} " \
            "deleted=#{deleted} blocked=#{blocked}"
          )
        end
      end

      { deleted: deleted, blocked: blocked }
    end

    def drain_series!(time_series_id)
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

      { deleted: series_deleted, blocked: series_blocked }
    end

    # Caller just wrote these rows to the archive — delete the same relation
    # without re-reading R2.
    def delete_exported!(relation)
      return 0 unless DailyArchive.prune_enabled?

      relation.delete_all
    end

    private

    def archived_days_for(time_series_id, year)
      archived_points_for(time_series_id, year).keys.to_set
    end

    def archived_points_for(time_series_id, year)
      cache_key = [ time_series_id, year ]
      @archived_points_cache[cache_key] ||= begin
        key = DailyArchive.object_key(time_series_id, year)
        Codec.decode(@store.get(key)).index_by { |point| point["d"] }
      end
    end
  end
end
