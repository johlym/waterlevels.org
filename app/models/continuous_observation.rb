class ContinuousObservation < ApplicationRecord
  belongs_to :time_series

  validates :observed_at, :value, presence: true
  validates :observed_at, uniqueness: { scope: :time_series_id }
end
