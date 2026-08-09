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
    def upsert(time_series_id:, points:)
      grouped = Codec.normalize_points(points).group_by { |p| Date.parse(p["d"]).year }
      return 0 if grouped.empty?
      raise Cloudflare::R2Client::Error, "R2 store disabled" unless @store.enabled?

      total = 0
      grouped.each do |year, year_points|
        total += upsert_year(time_series_id, year, year_points)
      end
      total
    end

    def upsert_from_daily_observations(time_series_id:, relation:)
      points = relation.pluck(:observed_on, :value, :approval_status).map do |day, value, approval|
        {
          "d" => day.iso8601,
          "v" => value.to_f,
          "s" => DailyArchive::SOURCE_USGS,
          "a" => approval
        }
      end
      upsert(time_series_id: time_series_id, points: points)
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
        shard = DailyArchiveShard.find_or_initialize_by(time_series_id: time_series_id, year: year)
        shard.assign_attributes(
          object_key: key,
          point_count: merged.size,
          min_on: dates.min,
          max_on: dates.max,
          content_sha256: digest,
          source_mix: Codec.source_mix(merged),
          synced_at: Time.current
        )
        shard.save!
        merged.size
      ensure
        Rails.cache.delete(lock_key)
      end
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
