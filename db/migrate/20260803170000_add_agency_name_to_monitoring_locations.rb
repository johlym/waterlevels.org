class AddAgencyNameToMonitoringLocations < ActiveRecord::Migration[8.1]
  def change
    add_column :monitoring_locations, :agency_name, :string
  end
end
