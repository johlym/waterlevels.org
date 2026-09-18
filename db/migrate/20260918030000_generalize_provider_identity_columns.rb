class GeneralizeProviderIdentityColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :monitoring_locations, :data_provider, :string, null: false, default: "usgs"

    # PostgreSQL adapter renames the unique indexes along with the columns.
    rename_column :monitoring_locations, :usgs_monitoring_location_id, :provider_location_id
    rename_column :time_series, :usgs_time_series_id, :provider_series_id

    add_index :monitoring_locations, :data_provider,
      name: "index_monitoring_locations_on_data_provider"
  end
end
