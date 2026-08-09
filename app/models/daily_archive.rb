# R2 (or local disk) is the daily system of record; Postgres keeps a short
# scratch tip of recent dailies plus ~35 days of continuous IV.
# See doc/postgres-r2-daily-archive.md.
require "set"

module DailyArchive
  # Postgres daily scratch tip — not history SoR. Override with DAILY_ARCHIVE_HOT_RETENTION_DAYS.
  DAILY_SCRATCH_RETENTION = 7.days
  DAILY_HOT_RETENTION = DAILY_SCRATCH_RETENTION # back-compat alias
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
    # Scratch-tip cutoff. DAILY_ARCHIVE_HOT_RETENTION_DAYS overrides (local demo).
    days = ENV["DAILY_ARCHIVE_HOT_RETENTION_DAYS"].to_s.strip
    if days.match?(/\A\d+\z/) && days.to_i.positive?
      days.to_i.days.ago.to_date
    else
      DAILY_SCRATCH_RETENTION.ago.to_date
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

  # Relation selecting time_series_id for series with a daily on/before anchor in
  # hot Postgres and/or cold shard catalog. UNION (not OR-through-time_series)
  # keeps the plan as two indexable range scans.
  def time_series_ids_with_daily_on_or_before(anchor)
    return DailyObservation.none.select(:time_series_id) if anchor.blank?

    hot = DailyObservation.where(observed_on: ..anchor).select(:time_series_id)
    cold = DailyArchiveShard.where(min_on: ..anchor).select(:time_series_id)
    DailyObservation
      .select(:time_series_id)
      .from(Arel.sql("(#{hot.to_sql} UNION #{cold.to_sql}) AS daily_observations"))
  end

  # Set of series ids with daily coverage on/before anchor — for in-Ruby admin aggregates.
  def daily_coverage_series_ids(anchor)
    return Set.new if anchor.blank?

    hot = DailyObservation.where(observed_on: ..anchor).distinct.pluck(:time_series_id)
    cold = DailyArchiveShard.where(min_on: ..anchor).distinct.pluck(:time_series_id)
    hot.to_set.merge(cold)
  end

  # Points in year shards entirely older than the scratch tip — no overlap with
  # daily_observations after prune. Boundary-year cold days may still sit only
  # in a straddling shard and are omitted (undercount) rather than double-counted.
  def cold_archive_point_count
    DailyArchiveShard.where(max_on: ...hot_cutoff_on).sum(:point_count).to_i
  end

  def shard_count
    DailyArchiveShard.count
  end
end
