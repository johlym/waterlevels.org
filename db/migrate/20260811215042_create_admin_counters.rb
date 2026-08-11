class CreateAdminCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_counters do |t|
      t.string :name, null: false
      t.bigint :value, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.datetime :computed_at, null: false
      t.string :source, null: false, default: "job"
      t.timestamps
    end

    add_index :admin_counters, :name, unique: true
  end
end
