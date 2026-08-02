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

  def stale?
    latest_observed_at.blank? || latest_observed_at < STALE_AFTER.ago
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
end
