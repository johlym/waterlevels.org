class AddUsgsDailyAbsentToTimeSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :time_series, :usgs_daily_absent, :boolean, null: false, default: false
  end
end
