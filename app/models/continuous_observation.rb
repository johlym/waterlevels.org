class ContinuousObservation < ApplicationRecord
  belongs_to :time_series

  validates :observed_at, :value, presence: true
  validates :observed_at, uniqueness: { scope: :time_series_id }

  # Keep denorm columns in sync for AR create/destroy (tests + rare paths).
  # Bulk upsert_all / insert_all / delete_all bypass callbacks — those callers
  # already invoke TimeSeries.refresh_continuous_coverage! / advance_continuous_tips!.
  after_commit :refresh_time_series_coverage, on: %i[create destroy]

  private

  def refresh_time_series_coverage
    TimeSeries.refresh_continuous_coverage!([ time_series_id ])
  end
end
