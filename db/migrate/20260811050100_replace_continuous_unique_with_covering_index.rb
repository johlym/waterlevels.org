class ReplaceContinuousUniqueWithCoveringIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  NEW_INDEX = "index_continuous_observations_on_ts_observed_at_incl_value"
  OLD_INDEX = "idx_on_time_series_id_observed_at_6d681681d4"
  REDUNDANT_FK = "index_continuous_observations_on_time_series_id"

  def up
    # Covering unique for HydrographSeries pluck(observed_at, value) index-only scans.
    # CREATE INDEX CONCURRENTLY on continuous_observations can take a while — prefer
    # `heroku run 'bundle exec rails db:migrate'` and let it finish; do not kill the dyno.
    add_index :continuous_observations, %i[time_series_id observed_at],
      unique: true,
      include: :value,
      name: NEW_INDEX,
      algorithm: :concurrently,
      if_not_exists: true

    remove_index :continuous_observations, name: OLD_INDEX,
      algorithm: :concurrently,
      if_exists: true

    # Leftmost of the unique composite — safe once NEW_INDEX exists.
    remove_index :continuous_observations, name: REDUNDANT_FK,
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :continuous_observations, :time_series_id,
      name: REDUNDANT_FK,
      algorithm: :concurrently,
      if_not_exists: true

    add_index :continuous_observations, %i[time_series_id observed_at],
      unique: true,
      name: OLD_INDEX,
      algorithm: :concurrently,
      if_not_exists: true

    remove_index :continuous_observations, name: NEW_INDEX,
      algorithm: :concurrently,
      if_exists: true
  end
end
