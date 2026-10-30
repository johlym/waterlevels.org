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
    # Coalesce a loop of creates into one coverage UPDATE. The flush runs
    # before the next statement that is not itself a continuous_observations
    # read/write, and again at the end of the request or example.
    TimeSeries.enqueue_coverage_refresh!(time_series_id)
  end
end
