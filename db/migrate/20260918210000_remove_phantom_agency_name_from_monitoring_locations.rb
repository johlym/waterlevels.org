class RemovePhantomAgencyNameFromMonitoringLocations < ActiveRecord::Migration[8.1]
  # schema.rb listed agency_name after an Aug 2026 dump, but no migration
  # created the column. Production therefore raises UnknownAttributeError
  # when provider syncs assign it. Drop the column where a schema load
  # created it; no-op on databases that only ran migrations.
  def up
    return unless column_exists?(:monitoring_locations, :agency_name)

    remove_column :monitoring_locations, :agency_name, :string
  end

  def down
    return if column_exists?(:monitoring_locations, :agency_name)

    add_column :monitoring_locations, :agency_name, :string
  end
end
