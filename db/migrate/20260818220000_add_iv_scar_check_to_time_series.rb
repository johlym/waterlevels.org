class AddIvScarCheckToTimeSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :time_series, :iv_scar_checked_at, :datetime
    add_column :time_series, :iv_scar_checked_max_gap_seconds, :integer
  end
end
