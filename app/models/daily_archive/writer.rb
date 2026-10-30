module DailyArchive
  class Writer
    LOCK_PREFIX = "daily_archive_write:"
    LOCK_TTL = 2.minutes
    # Sidekiq concurrency lets prune/export/backfill rewrite the same year shard.
    # Wait long enough to cover a typical R2 get/merge/put + catalog update.
    LOCK_WAIT = 30.seconds
    LOCK_SLEEP_INITIAL = 0.05
    LOCK_SLEEP_MAX = 1.0

    # Transient contention on a year shard — callers may retry or skip.
    class LockBusyError < Cloudflare::R2Client::Error; end

    def initialize(store: DailyArchive.store, sleeper: nil, lock_wait: LOCK_WAIT)
      @store = store
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @lock_wait = lock_wait
    end

    # points: array of hashes with observed_on/value or d/v, plus optional source/approval_status
    def upsert(time_series_id:, points:, series: nil)
      grouped = Codec.normalize_points(points).group_by { |p| Date.parse(p["d"]).year }
      return 0 if grouped.empty?
      raise Cloudflare::R2Client::Error, "R2 store disabled" unless @store.enabled?

      remember_series!(series) if series
      preload_shards!([ time_series_id ])
      ensure_series!([ time_series_id ])

      total = 0
      grouped.each do |year, year_points|
        total += upsert_year(time_series_id, year, year_points)
      end
      total
    end

    def upsert_from_daily_observations(time_series_id:, relation:, series: nil)
      rows = relation.except(:order).pluck(:observed_on, :value, :approval_status)
      return 0 if rows.empty?

      points = rows.map do |day, value, approval|
        {
          "d" => day.iso8601,
          "v" => value.to_f,
          "s" => DailyArchive::SOURCE_USGS,
          "a" => approval
        }
      end
      upsert(time_series_id: time_series_id, points: points, series: series)
    end

    # Load parent series and year-shard rows for a batch so later upserts do
    # not repeat find_or_initialize / belongs_to lookups.
    def preload_series!(series_list)
      Array(series_list).compact.each { |series| remember_series!(series) }
    end

    def preload_shards!(time_series_ids)
      ids = Array(time_series_ids).map(&:to_i).uniq
      @shards ||= {}
      @shard_series_loaded ||= Set.new
      missing = ids.reject { |id| @shard_series_loaded.include?(id) }
      return if missing.empty?

      DailyArchiveShard.where(time_series_id: missing).each do |shard|
        @shards[[ shard.time_series_id, shard.year ]] = shard
      end
      missing.each { |id| @shard_series_loaded << id }
    end

    private

    def upsert_year(time_series_id, year, year_points)
      key = DailyArchive.object_key(time_series_id, year)
      lock_key = "#{LOCK_PREFIX}#{time_series_id}:#{year}"
      acquire_lock!(lock_key, key)

      begin
        existing = Codec.decode(@store.get(key))
        merged = Codec.merge(existing, year_points)
        body = Codec.encode(merged)
        digest = Digest::SHA256.hexdigest(body)
        @store.put(key, body)

        dates = merged.map { |p| Date.parse(p["d"]) }
        series = series_for(time_series_id)
        shard = @shards[[ time_series_id, year ]]
        if shard
          shard.time_series = series if series
        else
          shard = DailyArchiveShard.new(time_series: series, time_series_id: time_series_id, year: year)
          @shards[[ time_series_id, year ]] = shard
        end
        shard.assign_attributes(
          object_key: key,
          point_count: merged.size,
          min_on: dates.min,
          max_on: dates.max,
          content_sha256: digest,
          source_mix: Codec.source_mix(merged),
          synced_at: Time.current
        )
        # The year lock already serializes writers. Skipping validations avoids a
        # uniqueness SELECT per year when one series spans several shards.
        if shard.persisted?
          shard.update_columns(
            object_key: shard.object_key,
            point_count: shard.point_count,
            min_on: shard.min_on,
            max_on: shard.max_on,
            content_sha256: shard.content_sha256,
            source_mix: shard.source_mix,
            synced_at: shard.synced_at,
            updated_at: Time.current
          )
        else
          shard.save!(validate: false)
        end
        series&.clear_daily_bounds!
        MonitoringLocation.invalidate_selected_series_cache!
        merged.size
      ensure
        Rails.cache.delete(lock_key)
      end
    end

    def remember_series!(series)
      return if series.nil?

      (@series_by_id ||= {})[series.id] = series
    end

    def ensure_series!(time_series_ids)
      ids = Array(time_series_ids).map(&:to_i).uniq
      @series_by_id ||= {}
      missing = ids.reject { |id| @series_by_id.key?(id) }
      return if missing.empty?

      TimeSeries.where(id: missing).each { |series| @series_by_id[series.id] = series }
    end

    def series_for(time_series_id)
      @series_by_id&.[](time_series_id.to_i)
    end

    def acquire_lock!(lock_key, key)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_wait.to_f
      sleep_for = LOCK_SLEEP_INITIAL

      loop do
        return if Rails.cache.write(lock_key, true, expires_in: LOCK_TTL, unless_exist: true)

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          raise LockBusyError, "archive write lock busy key=#{key}"
        end

        @sleeper.call([ sleep_for, remaining ].min)
        sleep_for = [ sleep_for * 2, LOCK_SLEEP_MAX ].min
      end
    end
  end
end
