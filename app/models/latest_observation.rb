class LatestObservation < ApplicationRecord
  belongs_to :time_series

  validates :observed_at, :value, :synced_at, presence: true
end
