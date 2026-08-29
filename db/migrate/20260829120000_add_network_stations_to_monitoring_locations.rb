class AddNetworkStationsToMonitoringLocations < ActiveRecord::Migration[8.1]
  def change
    add_column :monitoring_locations, :upstream_station_ids, :jsonb, null: false, default: []
    add_column :monitoring_locations, :downstream_station_ids, :jsonb, null: false, default: []
    add_column :monitoring_locations, :network_synced_at, :datetime
  end
end
