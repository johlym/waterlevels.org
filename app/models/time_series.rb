class TimeSeries < ApplicationRecord
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

  # Hot tip and/or cold R2 shard catalog — deep anchors leave Postgres after prune.
  def has_daily_on_or_before?(anchor)
    return false if anchor.blank?

    daily_observations.where(observed_on: ..anchor).exists? ||
      daily_archive_shards.where(min_on: ..anchor).exists?
  end
end
