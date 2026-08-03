class AddIndexOnMonitoringLocationsNwpsLid < ActiveRecord::Migration[8.1]
  def change
    add_index :monitoring_locations, :nwps_lid, where: "nwps_lid IS NOT NULL"
  end
end
