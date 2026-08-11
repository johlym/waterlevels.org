class AddSelectedAndStaleCoverageIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Global TimeSeries.selected / selected_recently_active filters — the
    # (location, kind, selected) composite cannot lead with selected_for_display.
    add_index :time_series, :monitoring_location_id,
      name: "index_time_series_selected_on_location",
      where: "selected_for_display = TRUE",
      algorithm: :concurrently,
      if_not_exists: true

    # MonitoringLocation.not_stale / tip-freshness histograms.
    add_index :monitoring_locations, %i[active latest_observed_at],
      name: "index_monitoring_locations_on_active_and_latest_observed_at",
      algorithm: :concurrently,
      if_not_exists: true

    # Redundant with unique/composite leftmost prefixes — drop to cut upsert write cost.
    remove_index :daily_observations, name: "index_daily_observations_on_time_series_id",
      algorithm: :concurrently,
      if_exists: true
    remove_index :peak_observations, name: "index_peak_observations_on_time_series_id",
      algorithm: :concurrently,
      if_exists: true
    remove_index :daily_archive_shards, name: "index_daily_archive_shards_on_time_series_id",
      algorithm: :concurrently,
      if_exists: true
    # Covered by index_time_series_on_location_kind_selected (location leftmost)
    # plus the new selected partial above.
    remove_index :time_series, name: "index_time_series_on_monitoring_location_id",
      algorithm: :concurrently,
      if_exists: true
  end
end
