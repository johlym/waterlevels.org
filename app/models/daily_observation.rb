class DailyObservation < ApplicationRecord
  belongs_to :time_series

  validates :observed_on, :value, presence: true
  validates :observed_on, uniqueness: { scope: :time_series_id }

  after_commit :invalidate_selected_series_cache

  private

  def invalidate_selected_series_cache
    MonitoringLocation.invalidate_selected_series_cache!
  end
end
