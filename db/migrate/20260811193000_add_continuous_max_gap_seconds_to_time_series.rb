class AddContinuousMaxGapSecondsToTimeSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :time_series, :continuous_max_gap_seconds, :integer

    # Fleet scar-lane eligibility: selected + anchored series with a large
    # interior IV hole (denorm refreshed by TimeSeries.refresh_continuous_coverage!).
    add_index :time_series,
      :continuous_max_gap_seconds,
      name: "index_time_series_selected_anchored_on_max_gap",
      where: "selected_for_display = true AND has_continuous_anchor = true"
  end
end
