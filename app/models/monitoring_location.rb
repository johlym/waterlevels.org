class MonitoringLocation < ApplicationRecord
  STALE_AFTER = 1.week

  has_many :time_series, dependent: :destroy
  has_many :selected_time_series, -> { where(selected_for_display: true) }, class_name: "TimeSeries"

  validates :usgs_monitoring_location_id, :site_number, :name, :slug, :state_code, :latitude, :longitude, presence: true
  validates :usgs_monitoring_location_id, :site_number, uniqueness: true

  scope :in_state, ->(code) { where(state_code: code.to_s.downcase) }
  scope :ordered_for_state_table, -> { order(Arel.sql("LOWER(COALESCE(county_name, '')) ASC, LOWER(name) ASC")) }
  scope :in_bbox, lambda { |west, south, east, north|
    where(latitude: south..north, longitude: west..east)
  }
  scope :search, lambda { |query|
    q = query.to_s.strip
    return none if q.blank?

    pattern = "%#{sanitize_sql_like(q)}%"
    where(
      "name ILIKE :pattern OR site_number ILIKE :pattern OR state_code ILIKE :pattern OR state_name ILIKE :pattern OR COALESCE(county_name, '') ILIKE :pattern",
      pattern: pattern
    ).order(
      Arel.sql(
        sanitize_sql_array([
          "CASE
            WHEN site_number = :exact THEN 0
            WHEN site_number ILIKE :prefix THEN 1
            WHEN name ILIKE :prefix THEN 2
            ELSE 3
          END, name ASC",
          { exact: q, prefix: "#{sanitize_sql_like(q)}%" }
        ])
      )
    )
  }
  scope :needing_history_backfill, lambda {
    continuous_since = HistoryIngestion::CONTINUOUS_FRESHNESS.ago
    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    missing_continuous = TimeSeries.selected.where.not(
      id: ContinuousObservation.where(observed_at: continuous_since..).select(:time_series_id)
    )
    missing_daily_anchor = TimeSeries.selected.where.not(
      id: DailyObservation.where(observed_on: ..daily_anchor).select(:time_series_id)
    )
    stale_daily_tip = TimeSeries.selected.where.not(
      id: DailyObservation.where(observed_on: daily_fresh_since..).select(:time_series_id)
    )
    where(id: missing_continuous.select(:monitoring_location_id))
      .or(where(id: missing_daily_anchor.select(:monitoring_location_id)))
      .or(where(id: stale_daily_tip.select(:monitoring_location_id)))
      .distinct
  }

  def stale?
    latest_observed_at.blank? || latest_observed_at < STALE_AFTER.ago
  end

  def needs_history_backfill?
    series = time_series.selected
    return false if series.none?

    continuous_since = HistoryIngestion::CONTINUOUS_FRESHNESS.ago
    daily_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    series.any? do |s|
      s.continuous_observations.where(observed_at: continuous_since..).none? ||
        s.daily_observations.where(observed_on: ..daily_anchor).none? ||
        s.daily_observations.where(observed_on: daily_fresh_since..).none?
    end
  end

  def to_param
    "#{site_number}-#{slug}"
  end

  def path_state
    state_code.to_s.downcase
  end

  # IANA zone for the USGS `time_zone` abbreviation (e.g. CST → America/Chicago).
  def time_zone_identifier
    Usgs::TimeZones.iana_identifier(time_zone, state_code: state_code)
  end

  def measurement_kinds
    kinds = []
    kinds << "water_level" if has_water_level?
    kinds << "discharge" if has_discharge?
    kinds << "temperature" if has_temperature?
    kinds
  end

  def self.slug_for(name)
    name.to_s.parameterize.presence || "gauge"
  end

  # Hard-delete locations and dependent rows without AR callbacks (fast purge).
  def self.purge_ids!(ids)
    ids = Array(ids).compact.uniq
    return 0 if ids.empty?

    ts_ids = TimeSeries.where(monitoring_location_id: ids).pluck(:id)
    if ts_ids.any?
      LatestObservation.where(time_series_id: ts_ids).delete_all
      ContinuousObservation.where(time_series_id: ts_ids).delete_all
      DailyObservation.where(time_series_id: ts_ids).delete_all
      PeakObservation.where(time_series_id: ts_ids).delete_all
      TimeSeries.where(id: ts_ids).delete_all
    end
    where(id: ids).delete_all
  end
end
