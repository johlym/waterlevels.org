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
      continuous_observations.maximum(:observed_at),
      ends_at
    ].compact.max
    return true if tip_at.blank?

    tip_at >= HistoryIngestion::CONTINUOUS_RETENTION.before(as_of)
  end
end
