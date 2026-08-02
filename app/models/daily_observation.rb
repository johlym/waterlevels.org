class DailyObservation < ApplicationRecord
  belongs_to :time_series

  validates :observed_on, :value, presence: true
  validates :observed_on, uniqueness: { scope: :time_series_id }
end
