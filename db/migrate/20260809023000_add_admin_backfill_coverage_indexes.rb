class AddAdminBackfillCoverageIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Admin/backfill eligibility probes "any point on/before anchor" without a
    # time_series_id predicate — the existing (time_series_id, observed_on)
    # unique index cannot serve that plan.
    add_index :daily_observations, :observed_on,
      name: "index_daily_observations_on_observed_on",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :daily_archive_shards, :min_on,
      name: "index_daily_archive_shards_on_min_on",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :daily_archive_shards, :max_on,
      name: "index_daily_archive_shards_on_max_on",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
