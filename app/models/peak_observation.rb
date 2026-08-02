class PeakObservation < ApplicationRecord
  belongs_to :time_series

  validates :water_year, :value, :peak_kind, presence: true
  validates :water_year, uniqueness: { scope: %i[time_series_id peak_kind] }
end
