class AddContinuousCoverageToTimeSeries < ActiveRecord::Migration[8.1]
  def change
    change_table :time_series, bulk: true do |t|
      t.datetime :continuous_newest_at
      t.datetime :continuous_prev_at
      t.boolean :has_continuous_anchor, null: false, default: false
    end
  end
end
