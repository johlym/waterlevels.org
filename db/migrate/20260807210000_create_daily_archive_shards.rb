class CreateDailyArchiveShards < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_archive_shards do |t|
      t.references :time_series, null: false, foreign_key: true
      t.integer :year, null: false
      t.string :object_key, null: false
      t.integer :point_count, null: false, default: 0
      t.date :min_on
      t.date :max_on
      t.string :content_sha256, null: false
      t.string :source_mix, null: false, default: "usgs"
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :daily_archive_shards, %i[time_series_id year], unique: true
    add_index :daily_archive_shards, :object_key, unique: true
  end
end
