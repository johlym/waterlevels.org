class AddDisplayAndSearchNamesToMonitoringLocations < ActiveRecord::Migration[8.1]
  def up
    add_column :monitoring_locations, :display_name, :string
    add_column :monitoring_locations, :search_name, :string

    say_with_time "backfill display_name and search_name" do
      MonitoringLocation.reset_column_information
      MonitoringLocation.find_each(batch_size: 500) do |location|
        display = Usgs::LocationNames.format(location.name)
        location.update_columns(
          display_name: display,
          search_name: display.downcase
        )
      end
    end

    change_column_null :monitoring_locations, :display_name, false
    change_column_null :monitoring_locations, :search_name, false

    add_index :monitoring_locations, :search_name
  end

  def down
    remove_index :monitoring_locations, :search_name
    remove_column :monitoring_locations, :search_name
    remove_column :monitoring_locations, :display_name
  end
end
