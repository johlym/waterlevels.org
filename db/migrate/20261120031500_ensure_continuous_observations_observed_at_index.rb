# frozen_string_literal: true

class EnsureContinuousObservationsObservedAtIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "index_continuous_observations_on_observed_at"

  def up
    # 20260803070000 is already recorded on production, and this index is
    # missing there. Fleet-wide retention walks filter on observed_at alone.
    # if_not_exists keeps databases that already built the index unchanged.
    # On production this builds an index over tens of millions of rows.
    # Let the migration finish; do not kill the dyno.
    add_index :continuous_observations, :observed_at,
              name: INDEX,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    # The index belongs to 20260803070000. Rolling back this repair leaves it.
  end
end
