# R2 (or local disk) is the daily system of record. Postgres keeps ~35 days of
# continuous IV only — not daily history. Legacy daily_observations rows drain
# immediately after export, on the 6-hour leftover job, and during nightly
# retention when DAILY_ARCHIVE_PRUNE is on.
# See doc/postgres-r2-daily-archive.md.
require "set"

module DailyArchive
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
    configured? && AppConfig.boolean?(:daily_archive_reads)
  end

  def prune_enabled?
    configured? && AppConfig.boolean?(:daily_archive_prune)
  end

  # Periodic leftover drain (export-after-shuttle + already-in-R2 deletes).
  def drain_enabled?
    prune_enabled? && AppConfig.boolean?(:daily_archive_drain_enabled)
  end

  # When enabled, ingest writes dailies to the archive only (not Postgres).
  # Name kept for env compatibility; set DAILY_ARCHIVE_DUAL_WRITE=0 (or admin
  # override) to pause archive writes.
  def dual_write_enabled?
    configured? && AppConfig.boolean?(:daily_archive_dual_write)
  end

  def archive_writes_enabled?
    dual_write_enabled?
  end

  def local_store?
    LOCAL_STORE_MODES.include?(ENV["DAILY_ARCHIVE_STORE"].to_s.strip.downcase)
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
  # leftover Postgres rows and/or shard catalog. UNION keeps two indexable scans.
  def time_series_ids_with_daily_on_or_before(anchor)
    return DailyObservation.none.select(:time_series_id) if anchor.blank?

    hot = DailyObservation.where(observed_on: ..anchor).select(:time_series_id)
    cold = DailyArchiveShard.where(min_on: ..anchor).select(:time_series_id)
    DailyObservation
      .select(:time_series_id)
      .from(Arel.sql("(#{hot.to_sql} UNION #{cold.to_sql}) AS daily_observations"))
  end

  def daily_coverage_series_ids(anchor)
    return Set.new if anchor.blank?

    hot = DailyObservation.where(observed_on: ..anchor).distinct.pluck(:time_series_id)
    cold = DailyArchiveShard.where(min_on: ..anchor).distinct.pluck(:time_series_id)
    hot.to_set.merge(cold)
  end

  # Series whose archive tip (shard max_on) is on/after the freshness floor.
  def time_series_ids_with_fresh_daily_tip(since_on)
    return DailyArchiveShard.none.select(:time_series_id) if since_on.blank?

    DailyArchiveShard.where(max_on: since_on..).select(:time_series_id)
  end

  # Fresh daily tip in leftover Postgres rows and/or R2 shard max_on.
  # Matches needing_history / needing_deep gates after DAILY_ARCHIVE_PRUNE.
  def fresh_daily_tip_series_ids(since_on)
    return Set.new if since_on.blank?

    hot = DailyObservation.where(observed_on: since_on..).distinct.pluck(:time_series_id)
    cold = DailyArchiveShard.where(max_on: since_on..).distinct.pluck(:time_series_id)
    hot.to_set.merge(cold)
  end

  def archive_point_count
    DailyArchiveShard.sum(:point_count).to_i
  end

  # Back-compat alias used by admin / site stats.
  def cold_archive_point_count
    archive_point_count
  end

  def shard_count
    DailyArchiveShard.count
  end
end
