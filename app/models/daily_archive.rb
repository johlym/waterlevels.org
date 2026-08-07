# Hot Postgres tip + cold Cloudflare R2 archive for daily means.
# See doc/postgres-r2-daily-archive.md.
module DailyArchive
  DAILY_HOT_RETENTION = 14.months
  CONTINUOUS_ROLLUP_AFTER = 30.days
  COVERAGE_RATIO = 0.80
  OBJECT_PREFIX = "daily/v1"
  SOURCE_USGS = "usgs"
  SOURCE_DERIVED = "derived"

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

    # Default on when R2 is configured; set DAILY_ARCHIVE_DUAL_WRITE=0 to pause.
    value = ENV["DAILY_ARCHIVE_DUAL_WRITE"]
    value.nil? || %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def hot_cutoff_on
    DAILY_HOT_RETENTION.ago.to_date
  end

  def cold?(day)
    day < hot_cutoff_on
  end

  def object_key(time_series_id, year)
    "#{OBJECT_PREFIX}/#{time_series_id}/#{year}.json.gz"
  end

  def store
    @store || Cloudflare::R2Client.new
  end

  def store=(value)
    @store = value
  end

  def reset_store!
    @store = nil
  end

  def env_flag?(name)
    %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
  end
end
