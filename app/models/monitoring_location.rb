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
  scope :needing_history_backfill, lambda { |since: 7.days.ago|
    selected_without_recent = TimeSeries.selected.where.not(
      id: ContinuousObservation.where(observed_at: since..).select(:time_series_id)
    )
    where(id: selected_without_recent.select(:monitoring_location_id)).distinct
  }

  def stale?
    latest_observed_at.blank? || latest_observed_at < STALE_AFTER.ago
  end

  def needs_history_backfill?(since: 7.days.ago)
    series = time_series.selected
    return false if series.none?

    series.any? { |s| s.continuous_observations.where(observed_at: since..).none? }
  end

  def to_param
    "#{site_number}-#{slug}"
  end

  def path_state
    state_code.to_s.downcase
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
