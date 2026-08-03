class AddObservedAtIndexToContinuousObservations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :continuous_observations, :observed_at,
              name: "index_continuous_observations_on_observed_at",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
