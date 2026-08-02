class CreateWaterlevelsSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :monitoring_locations do |t|
      t.string :agency_code, null: false, default: "USGS"
      t.string :usgs_monitoring_location_id, null: false
      t.string :site_number, null: false
      t.string :name, null: false
      t.string :slug, null: false
      t.string :site_type_code
      t.string :site_type_name
      t.decimal :latitude, precision: 10, scale: 7, null: false
      t.decimal :longitude, precision: 10, scale: 7, null: false
      t.string :state_code, null: false
      t.string :state_name
      t.string :county_code
      t.string :county_name
      t.string :hydrologic_unit_code
      t.decimal :drainage_area, precision: 12, scale: 3
      t.string :time_zone
      t.boolean :active, null: false, default: true
      t.datetime :metadata_synced_at

      t.decimal :latest_water_level_value, precision: 16, scale: 6
      t.string :latest_water_level_parameter_code
      t.string :latest_water_level_unit
      t.decimal :latest_discharge_value, precision: 16, scale: 6
      t.string :latest_discharge_unit
      t.decimal :latest_temperature_c, precision: 8, scale: 3
      t.datetime :latest_observed_at
      t.string :latest_approval_status
      t.boolean :has_water_level, null: false, default: false
      t.boolean :has_discharge, null: false, default: false
      t.boolean :has_temperature, null: false, default: false
      t.jsonb :nearby_station_ids, null: false, default: []

      t.timestamps
    end

    add_index :monitoring_locations, :usgs_monitoring_location_id, unique: true
    add_index :monitoring_locations, :site_number, unique: true
    add_index :monitoring_locations, [:state_code, :county_name, :name]
    add_index :monitoring_locations, [:latitude, :longitude]
    add_index :monitoring_locations, :has_water_level, where: "has_water_level = TRUE"
    add_index :monitoring_locations, :has_discharge, where: "has_discharge = TRUE"

    create_table :time_series do |t|
      t.references :monitoring_location, null: false, foreign_key: true
      t.string :usgs_time_series_id, null: false
      t.string :parameter_code, null: false
      t.string :parameter_name
      t.string :parameter_description
      t.string :statistic_code
      t.string :statistic_name
      t.string :unit_of_measure
      t.string :measurement_kind, null: false
      t.boolean :primary_series, null: false, default: false
      t.boolean :selected_for_display, null: false, default: false
      t.datetime :begins_at
      t.datetime :ends_at
      t.datetime :metadata_synced_at
      t.timestamps
    end

    add_index :time_series, :usgs_time_series_id, unique: true
    add_index :time_series, [:monitoring_location_id, :measurement_kind, :selected_for_display],
              name: "index_time_series_on_location_kind_selected"

    create_table :latest_observations do |t|
      t.references :time_series, null: false, foreign_key: true, index: { unique: true }
      t.datetime :observed_at, null: false
      t.decimal :value, precision: 16, scale: 6, null: false
      t.string :unit_of_measure
      t.string :approval_status
      t.string :qualifier
      t.datetime :source_last_modified_at
      t.datetime :synced_at, null: false
      t.timestamps
    end

    create_table :daily_observations do |t|
      t.references :time_series, null: false, foreign_key: true
      t.date :observed_on, null: false
      t.decimal :value, precision: 16, scale: 6, null: false
      t.string :approval_status
      t.string :qualifier
      t.timestamps
    end

    add_index :daily_observations, [:time_series_id, :observed_on], unique: true

    create_table :continuous_observations do |t|
      t.references :time_series, null: false, foreign_key: true
      t.datetime :observed_at, null: false
      t.decimal :value, precision: 16, scale: 6, null: false
      t.string :approval_status
      t.string :qualifier
      t.timestamps
    end

    add_index :continuous_observations, [:time_series_id, :observed_at], unique: true

    create_table :peak_observations do |t|
      t.references :time_series, null: false, foreign_key: true
      t.integer :water_year, null: false
      t.datetime :observed_at
      t.decimal :value, precision: 16, scale: 6, null: false
      t.string :peak_kind, null: false, default: "high"
      t.string :approval_status
      t.timestamps
    end

    add_index :peak_observations, [:time_series_id, :water_year, :peak_kind], unique: true,
              name: "index_peak_observations_unique"
  end
end
