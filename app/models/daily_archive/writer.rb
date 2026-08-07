module DailyArchive
  class Writer
    LOCK_PREFIX = "daily_archive_write:"
    LOCK_TTL = 2.minutes

    def initialize(store: DailyArchive.store)
      @store = store
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
      unless Rails.cache.write(lock_key, true, expires_in: LOCK_TTL, unless_exist: true)
        # Another writer holds the shard; brief wait + retry once.
        sleep 0.05
        unless Rails.cache.write(lock_key, true, expires_in: LOCK_TTL, unless_exist: true)
          raise Cloudflare::R2Client::Error, "archive write lock busy key=#{key}"
        end
      end

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
  end
end
