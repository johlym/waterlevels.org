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

  validates :usgs_time_series_id, :parameter_code, :measurement_kind, presence: true
  validates :usgs_time_series_id, uniqueness: true

  scope :selected, -> { where(selected_for_display: true) }
  scope :for_kind, ->(kind) { where(measurement_kind: kind) }
  # Series USGS publishes daily DV for (or unknown). Excludes confirmed IV-only params.
  scope :expecting_daily, -> { where(usgs_daily_absent: false) }

  # Leftover Postgres rows and/or R2 shard catalog.
  def has_daily_on_or_before?(anchor)
    return false if anchor.blank?

    daily_observations.where(observed_on: ..anchor).exists? ||
      daily_archive_shards.where(min_on: ..anchor).exists?
  end

  def newest_daily_on
    [ daily_archive_shards.maximum(:max_on), daily_observations.maximum(:observed_on) ].compact.max
  end

  def oldest_daily_on
    [ daily_archive_shards.minimum(:min_on), daily_observations.minimum(:observed_on) ].compact.min
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
    window_start = HistoryIngestion::CONTINUOUS_RETENTION.before(as_of)
    return true if latest_observation&.observed_at&.>=(window_start)
    return true if continuous_observations.where(observed_at: window_start..).exists?

    false
  end

  # Long-inactive / POR-ended series should not stay in the recent history
  # backfill / cooldown loop (e.g. discharge that stopped in 2008).
  def eligible_for_recent_history_backfill?(as_of: Time.current)
    tip_at = [
      latest_observation&.observed_at,
      continuous_newest_at || continuous_observations.maximum(:observed_at),
      ends_at
    ].compact.max
    return true if tip_at.blank?

    tip_at >= HistoryIngestion::CONTINUOUS_RETENTION.before(as_of)
  end

  # Recompute continuous tip/prev/anchor denorm from continuous_observations.
  # Used after history upserts, retention prune, and one-shot backfill.
  # Eligibility scopes still read continuous_observations until Phase B flips.
  def self.refresh_continuous_coverage!(ids, as_of: Time.current)
    ids = Array(ids).map(&:to_i).uniq
    return 0 if ids.empty?

    anchor = connection.quote(HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR.before(as_of))
    id_list = ids.join(",")
    now = connection.quote(Time.current)
    sql = <<~SQL.squish
      UPDATE time_series AS ts
      SET continuous_newest_at = s.newest,
          continuous_prev_at = s.prev_at,
          has_continuous_anchor = s.has_anchor,
          updated_at = #{now}
      FROM (
        SELECT ts2.id AS time_series_id,
               MAX(co.observed_at) AS newest,
               (
                 ARRAY_AGG(co.observed_at ORDER BY co.observed_at DESC)
                   FILTER (WHERE co.id IS NOT NULL)
               )[2] AS prev_at,
               COALESCE(
                 BOOL_OR(co.observed_at IS NOT NULL AND co.observed_at <= #{anchor}),
                 FALSE
               ) AS has_anchor
        FROM time_series ts2
        LEFT JOIN continuous_observations co ON co.time_series_id = ts2.id
        WHERE ts2.id IN (#{id_list})
        GROUP BY ts2.id
      ) AS s
      WHERE ts.id = s.time_series_id
    SQL
    connection.update(sql)
  end

  # Cheap tip-path bump after LatestObservationSync / catalog discovery upserts.
  # Only moves newest forward (and shifts prev); never clears anchor.
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
          updated_at = #{now}
      FROM (VALUES #{values_sql}) AS tips(id, observed_at)
      WHERE ts.id = tips.id
    SQL
    connection.update(sql)
  end
end
