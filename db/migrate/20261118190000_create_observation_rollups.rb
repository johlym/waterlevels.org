class CreateObservationRollups < ActiveRecord::Migration[8.1]
  def up
    create_table :observation_rollups, primary_key: [ :dataset, :bucket, :shard ] do |t|
      t.integer :dataset, null: false, limit: 2
      t.datetime :bucket, null: false
      t.integer :shard, null: false, limit: 2
      t.bigint :point_count, null: false
      t.bigint :selected_point_count, null: false, default: 0
      t.timestamps
    end

    execute File.read(Rails.root.join("db/observation_rollups.sql"))
    # One-time seed. Later writes are maintained by the statement triggers.
    execute "SELECT observation_rollups_rebuild()"
  end

  def down
    %w[continuous_observations daily_observations peak_observations].each do |table|
      execute "DROP TRIGGER IF EXISTS observation_rollups_insert ON #{table}"
      execute "DROP TRIGGER IF EXISTS observation_rollups_delete ON #{table}"
    end
    execute "DROP FUNCTION IF EXISTS observation_rollups_apply_observed_at()"
    execute "DROP FUNCTION IF EXISTS observation_rollups_apply_observed_on()"
    execute "DROP FUNCTION IF EXISTS observation_rollups_rebuild()"
    drop_table :observation_rollups
  end
end
