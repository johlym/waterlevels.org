class AddNwpsFloodFieldsToMonitoringLocations < ActiveRecord::Migration[8.1]
  def change
    change_table :monitoring_locations, bulk: true do |t|
      t.string :nwps_lid
      t.boolean :nwps_matched, null: false, default: false
      t.datetime :nwps_synced_at
      t.decimal :flood_stage_action, precision: 16, scale: 6
      t.decimal :flood_stage_minor, precision: 16, scale: 6
      t.decimal :flood_stage_moderate, precision: 16, scale: 6
      t.decimal :flood_stage_major, precision: 16, scale: 6
      t.string :flood_category
      t.datetime :flood_category_observed_at
    end

    add_index :monitoring_locations, :flood_category
    add_index :monitoring_locations, :nwps_matched, where: "nwps_matched = TRUE"
  end
end
