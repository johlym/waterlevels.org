class TimeSeries < ApplicationRecord
  belongs_to :monitoring_location
  has_one :latest_observation, dependent: :destroy
  has_many :daily_observations, dependent: :destroy
  has_many :continuous_observations, dependent: :destroy
  has_many :peak_observations, dependent: :destroy

  validates :usgs_time_series_id, :parameter_code, :measurement_kind, presence: true
  validates :usgs_time_series_id, uniqueness: true

  scope :selected, -> { where(selected_for_display: true) }
  scope :for_kind, ->(kind) { where(measurement_kind: kind) }
end
