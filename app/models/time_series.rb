class TimeSeries < ApplicationRecord
  # Tip younger than this is treated as currently reported for display selection.
  # Matches MonitoringLocation#stale? so a quiet parameter drops off while the
  # station's other kinds are still live (e.g. discontinued temperature).
  REPORTING_TIP_WINDOW = MonitoringLocation::STALE_AFTER

  belongs_to :monitoring_location
  has_one :latest_observation, dependent: :destroy
  has_many :daily_observations, dependent: :destroy
  has_many :continuous_observations, dependent: :destroy
  has_many :peak_observations, dependent: :destroy
  has_many :daily_archive_shards, dependent: :destroy

  validates :provider_series_id, :parameter_code, :measurement_kind, presence: true
  validates :provider_series_id, uniqueness: true

  scope :selected, -> { where(selected_for_display: true) }
  scope :for_kind, ->(kind) { where(measurement_kind: kind) }
  # Series USGS publishes daily DV for (or unknown). Excludes confirmed IV-only params.
  scope :expecting_daily, -> { where(usgs_daily_absent: false) }
  scope :with_continuous_anchor, -> { where(has_continuous_anchor: true) }
  # Selected series that still look active for recent history / IV repair queues.
  # Uses denorm continuous_newest_at instead of scanning continuous_observations.
  scope :selected_recently_active, lambda { |as_of: Time.current|
    recent_since = HistoryIngestion.continuous_retention.before(as_of)
    selected.left_joins(:latest_observation).where(
      "(latest_observations.id IS NULL AND time_series.ends_at IS NULL) " \
      "OR latest_observations.observed_at >= ? OR time_series.ends_at >= ? " \
      "OR time_series.continuous_newest_at >= ?",
      recent_since,
      recent_since,
      recent_since
    )
  }

  # Leftover Postgres rows and/or R2 shard catalog.
  def has_daily_on_or_before?(anchor)
    return false if anchor.blank?

    if daily_bounds_loaded?
      return true if @daily_obs_min && @daily_obs_min <= anchor
      return true if @daily_shard_min && @daily_shard_min <= anchor

      false
    else
      daily_observations.where(observed_on: ..anchor).exists? ||
        daily_archive_shards.where(min_on: ..anchor).exists?
    end
  end

  def newest_daily_on
    if daily_bounds_loaded?
      [ @daily_shard_max, @daily_obs_max ].compact.max
    else
      [ daily_archive_shards.maximum(:max_on), daily_observations.maximum(:observed_on) ].compact.max
    end
  end

  def oldest_daily_on
    if daily_bounds_loaded?
      [ @daily_shard_min, @daily_obs_min ].compact.min
    else
      [ daily_archive_shards.minimum(:min_on), daily_observations.minimum(:observed_on) ].compact.min
    end
  end

  def clear_daily_bounds!
    @daily_bounds_loaded = false
  end

  def daily_bounds_loaded?
    @daily_bounds_loaded == true
  end

  # [start_epoch, end_epoch, observed_at array] captured by HistoryIngestion.
  def preloaded_continuous_gap_times
    return unless instance_variable_defined?(:@continuous_gap_times)

    @continuous_gap_times
  end

  def continuous_oldest_at
    if instance_variable_defined?(:@continuous_oldest_at)
      @continuous_oldest_at
    else
      continuous_observations.minimum(:observed_at)
    end
  end

  # True when this series still looks actively reported (fresh tip).
  # USGS metadata ends_at alone is unreliable between weekly catalog syncs —
  # tip age is what drives Partial rows and current-condition cards.
  def reporting?(as_of: Time.current)
    tip_at = latest_observation&.observed_at
    return false if tip_at.blank?

    tip_at >= REPORTING_TIP_WINDOW.before(as_of)
  end

  # False once history ingest confirmed USGS returns no daily DV for this
  # parameter (common for gage height at sites that only publish IV).
  def expects_daily_history?
    !usgs_daily_absent?
  end

  # Recent IV tip or continuous inside the retained window — required before we
  # conclude USGS "doesn't publish daily" (empty recent DV for a series that
  # ended years ago is not the same as IV-only).
  def recent_continuous_evidence?(as_of: Time.current)
    window_start = HistoryIngestion.continuous_retention.before(as_of)
    return true if latest_observation&.observed_at&.>=(window_start)
    return true if continuous_newest_at.present? && continuous_newest_at >= window_start

    false
  end

  # Long-inactive / POR-ended series should not stay in the recent history
  # backfill / cooldown loop (e.g. discharge that stopped in 2008).
  def eligible_for_recent_history_backfill?(as_of: Time.current)
    tip_at = [
      latest_observation&.observed_at,
      continuous_newest_at,
      ends_at
    ].compact.max
    return true if tip_at.blank?

    tip_at >= HistoryIngestion.continuous_retention.before(as_of)
  end

  # Recompute continuous tip/prev/anchor/max-gap denorm from continuous_observations.
  # Used after history upserts, retention prune, and one-shot backfill.
  # continuous_max_gap_seconds is the largest consecutive spacing inside the
  # retained IV window — drives the scar IV-repair lane (key2).
  def self.refresh_continuous_coverage!(ids, as_of: Time.current)
    ids = Array(ids).map(&:to_i).uniq
    return 0 if ids.empty?

    consume_coverage_refresh!(ids)

    anchor = connection.quote(HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.before(as_of))
    window_start = connection.quote(HistoryIngestion.continuous_retention.before(as_of))
    id_list = ids.join(",")
    now = connection.quote(Time.current)
    sql = <<~SQL.squish
      UPDATE time_series AS ts
      SET continuous_newest_at = s.newest,
          continuous_prev_at = s.prev_at,
          has_continuous_anchor = s.has_anchor,
          continuous_max_gap_seconds = s.max_gap_seconds,
          updated_at = #{now}
      FROM (
        SELECT ts2.id AS time_series_id,
               tips.newest,
               tips.prev_at,
               tips.has_anchor,
               COALESCE(gap.max_gap_seconds, 0) AS max_gap_seconds
        FROM time_series ts2
        LEFT JOIN LATERAL (
          SELECT MAX(co.observed_at) AS newest,
                 (
                   ARRAY_AGG(co.observed_at ORDER BY co.observed_at DESC)
                 )[2] AS prev_at,
                 COALESCE(
                   BOOL_OR(co.observed_at <= #{anchor}),
                   FALSE
                 ) AS has_anchor
          FROM continuous_observations co
          WHERE co.time_series_id = ts2.id
        ) tips ON TRUE
        LEFT JOIN LATERAL (
          SELECT MAX(g.gap_seconds) AS max_gap_seconds
          FROM (
            SELECT EXTRACT(EPOCH FROM (
                     co.observed_at - LAG(co.observed_at) OVER (ORDER BY co.observed_at)
                   ))::integer AS gap_seconds
            FROM continuous_observations co
            WHERE co.time_series_id = ts2.id
              AND co.observed_at >= #{window_start}
          ) g
        ) gap ON TRUE
        WHERE ts2.id IN (#{id_list})
      ) AS s
      WHERE ts.id = s.time_series_id
      RETURNING ts.id,
                ts.continuous_newest_at,
                ts.continuous_prev_at,
                ts.has_continuous_anchor,
                ts.continuous_max_gap_seconds
    SQL
    result = connection.exec_query(sql)
    @coverage_rows_by_id = result.to_a.index_by { |row| row["id"].to_i }
    MonitoringLocation.invalidate_selected_series_cache!
    result.rows.size
  end

  def self.coverage_attributes_for(id)
    row = @coverage_rows_by_id&.[](id.to_i)
    return if row.blank?

    gap = row["continuous_max_gap_seconds"]
    {
      continuous_newest_at: row["continuous_newest_at"],
      continuous_prev_at: row["continuous_prev_at"],
      has_continuous_anchor: ActiveModel::Type::Boolean.new.cast(row["has_continuous_anchor"]),
      continuous_max_gap_seconds: gap.nil? ? nil : gap.to_i
    }
  end

  # AR create/destroy of continuous rows defers the heavy coverage UPDATE so a
  # loop of inserts refreshes each series once.
  def self.enqueue_coverage_refresh!(time_series_id)
    (Thread.current[:coverage_refresh_ids] ||= []) << time_series_id.to_i
    MonitoringLocation.invalidate_selected_series_cache!
  end

  def self.flush_coverage_refresh!
    return if Thread.current[:flushing_coverage_refresh]

    ids = Thread.current[:coverage_refresh_ids]
    return if ids.blank?

    Thread.current[:flushing_coverage_refresh] = true
    begin
      Thread.current[:coverage_refresh_ids] = nil
      refresh_continuous_coverage!(ids)
    ensure
      Thread.current[:flushing_coverage_refresh] = false
    end
  end

  # Skip inserts into continuous_observations and transaction control so a loop
  # of creates refreshes once, on the next read that needs the denorm columns.
  def self.flush_coverage_refresh_before_query!(sql)
    return if Thread.current[:coverage_refresh_ids].blank?
    return if Thread.current[:flushing_coverage_refresh]

    return if write_prevented?

    text = sql.to_s
    return if text.include?("continuous_observations")
    return if text.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SHOW|SET)\b/i)

    flush_coverage_refresh!
  end

  def self.write_prevented?
    connection.respond_to?(:preventing_writes?) && connection.preventing_writes?
  end

  def self.consume_coverage_refresh!(ids)
    pending = Thread.current[:coverage_refresh_ids]
    return if pending.blank?

    drop = ids.map(&:to_i).to_set
    pending.reject! { |id| drop.include?(id.to_i) }
    Thread.current[:coverage_refresh_ids] = nil if pending.empty?
  end

  # One MIN/MAX pass so gauge and history code can ask about daily coverage
  # for every selected series without an exists? per series.
  def self.preload_daily_bounds!(series_list)
    series_list = Array(series_list).compact
    return if series_list.empty?

    ids = series_list.map(&:id)
    obs_rows = DailyObservation.where(time_series_id: ids).group(:time_series_id).pluck(
      :time_series_id,
      Arel.sql("MIN(observed_on)"),
      Arel.sql("MAX(observed_on)")
    )
    shard_rows = DailyArchiveShard.where(time_series_id: ids).group(:time_series_id).pluck(
      :time_series_id,
      Arel.sql("MIN(min_on)"),
      Arel.sql("MAX(max_on)")
    )
    obs_by_id = obs_rows.to_h { |id, min_on, max_on| [ id, [ min_on, max_on ] ] }
    shard_by_id = shard_rows.to_h { |id, min_on, max_on| [ id, [ min_on, max_on ] ] }

    series_list.each do |series|
      obs_min, obs_max = obs_by_id[series.id]
      shard_min, shard_max = shard_by_id[series.id]
      series.instance_variable_set(:@daily_obs_min, obs_min)
      series.instance_variable_set(:@daily_obs_max, obs_max)
      series.instance_variable_set(:@daily_shard_min, shard_min)
      series.instance_variable_set(:@daily_shard_max, shard_max)
      series.instance_variable_set(:@daily_bounds_loaded, true)
    end
  end

  # After a completed scar fetch, park series whose interior hole USGS could not
  # fill. Cleared when the hole drops below the gap threshold (filled or aged out).
  def self.record_iv_scar_check!(ids, checked_at: Time.current)
    ids = Array(ids).map(&:to_i).uniq
    return 0 if ids.empty?

    threshold = HistoryIngestion.continuous_gap_threshold.to_i
    now = "#{connection.quote(checked_at)}::timestamptz"
    updated = "#{connection.quote(Time.current)}::timestamptz"
    id_list = ids.join(",")
    sql = <<~SQL.squish
      UPDATE time_series
      SET iv_scar_checked_at = CASE
            WHEN has_continuous_anchor
              AND continuous_max_gap_seconds IS NOT NULL
              AND continuous_max_gap_seconds > #{threshold}
            THEN #{now}
            ELSE NULL
          END,
          iv_scar_checked_max_gap_seconds = CASE
            WHEN has_continuous_anchor
              AND continuous_max_gap_seconds IS NOT NULL
              AND continuous_max_gap_seconds > #{threshold}
            THEN continuous_max_gap_seconds
            ELSE NULL
          END,
          updated_at = #{updated}
      WHERE id IN (#{id_list})
    SQL
    connection.update(sql)
  end

  # Cheap tip-path bump after LatestObservationSync / catalog discovery upserts.
  # Only moves newest forward (and shifts prev); never clears anchor.
  # Also raises continuous_max_gap_seconds when the tip jump is larger than the
  # stored max — tip lane still owns tip-adjacent repair; scar denorm stays honest.
  # tips: { time_series_id => observed_at }
  def self.advance_continuous_tips!(tips)
    tips = tips.to_h.reject { |id, at| id.blank? || at.blank? }
    return 0 if tips.empty?

    # One tip per series — keep the newest observed_at when the buffer repeats.
    merged = tips.each_with_object({}) do |(id, at), hash|
      id = id.to_i
      at = at.utc
      hash[id] = at if hash[id].nil? || at > hash[id]
    end

    values_sql = merged.map { |id, at|
      "(#{id}::bigint, #{connection.quote(at)}::timestamptz)"
    }.join(", ")
    now = connection.quote(Time.current)
    sql = <<~SQL.squish
      UPDATE time_series AS ts
      SET continuous_prev_at = CASE
            WHEN ts.continuous_newest_at IS NULL THEN NULL
            WHEN tips.observed_at > ts.continuous_newest_at THEN ts.continuous_newest_at
            ELSE ts.continuous_prev_at
          END,
          continuous_newest_at = CASE
            WHEN ts.continuous_newest_at IS NULL OR tips.observed_at > ts.continuous_newest_at
              THEN tips.observed_at
            ELSE ts.continuous_newest_at
          END,
          continuous_max_gap_seconds = CASE
            WHEN ts.continuous_newest_at IS NOT NULL
              AND tips.observed_at > ts.continuous_newest_at
              THEN GREATEST(
                COALESCE(ts.continuous_max_gap_seconds, 0),
                EXTRACT(EPOCH FROM (tips.observed_at - ts.continuous_newest_at))::integer
              )
            ELSE ts.continuous_max_gap_seconds
          END,
          updated_at = #{now}
      FROM (VALUES #{values_sql}) AS tips(id, observed_at)
      WHERE ts.id = tips.id
    SQL
    connection.update(sql)
  end
end
