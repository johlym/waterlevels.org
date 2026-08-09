# Hot Postgres tip + cold Cloudflare R2 archive for daily means.
# See doc/postgres-r2-daily-archive.md.
module DailyArchive
  DAILY_HOT_RETENTION = 14.months
  CONTINUOUS_ROLLUP_AFTER = 30.days
  COVERAGE_RATIO = 0.80
  OBJECT_PREFIX = "daily/v1"
  SOURCE_USGS = "usgs"
  SOURCE_DERIVED = "derived"
  LOCAL_STORE_MODES = %w[local disk file].freeze

  module_function

  def configured?
    store.enabled?
  end

  def reads_enabled?
    configured? && env_flag?("DAILY_ARCHIVE_READS")
  end

  def prune_enabled?
    configured? && env_flag?("DAILY_ARCHIVE_PRUNE")
  end

  def dual_write_enabled?
    return false unless configured?

    # Default on when a store is configured; set DAILY_ARCHIVE_DUAL_WRITE=0 to pause.
    value = ENV["DAILY_ARCHIVE_DUAL_WRITE"]
    value.nil? || %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def local_store?
    LOCAL_STORE_MODES.include?(ENV["DAILY_ARCHIVE_STORE"].to_s.strip.downcase)
  end

  def hot_cutoff_on
    # Optional shorter tip for local demo seeds (e.g. DAILY_ARCHIVE_HOT_RETENTION_DAYS=7).
    days = ENV["DAILY_ARCHIVE_HOT_RETENTION_DAYS"].to_s.strip
    if days.match?(/\A\d+\z/) && days.to_i.positive?
      days.to_i.days.ago.to_date
    else
      DAILY_HOT_RETENTION.ago.to_date
    end
  end

  def cold?(day)
    day < hot_cutoff_on
  end

  def object_key(time_series_id, year)
    "#{OBJECT_PREFIX}/#{time_series_id}/#{year}.json.gz"
  end

  def store
    @store || build_store
  end

  def store=(value)
    @store = value
  end

  def reset_store!
    @store = nil
  end

  def build_store
    # Tests inject MemoryStore explicitly. Ignore DAILY_ARCHIVE_STORE=local from a
    # developer .env so the suite stays offline and deterministic (same idea as
    # not setting REDIS_URL for tests).
    if local_store? && !(Rails.env.test? && !env_flag?("DAILY_ARCHIVE_ALLOW_LOCAL_IN_TEST"))
      return DiskStore.new
    end

    Cloudflare::R2Client.new
  end

  def env_flag?(name)
    %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
  end

  # time_series.id relation: daily present on/before anchor in hot Postgres and/or
  # cold shard catalog (min_on). Used by backfill eligibility and admin backlog.
  def time_series_ids_with_daily_on_or_before(anchor)
    return TimeSeries.none if anchor.blank?

    hot = DailyObservation.where(observed_on: ..anchor).select(:time_series_id)
    cold = DailyArchiveShard.where(min_on: ..anchor).select(:time_series_id)
    TimeSeries.where(id: hot).or(TimeSeries.where(id: cold)).select(:id)
  end

  # Points in year shards entirely older than the hot tip — no overlap with
  # daily_observations after prune. Boundary-year cold days may still sit only
  # in a straddling shard and are omitted (undercount) rather than double-counted.
  def cold_archive_point_count
    DailyArchiveShard.where(max_on: ...hot_cutoff_on).sum(:point_count).to_i
  end
end
