# frozen_string_literal: true

class CreateEmailAlertsSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :subscribers do |t|
      t.string :email, null: false
      t.datetime :verified_at
      t.string :time_zone, null: false, default: "America/New_York"
      t.integer :digest_hour, null: false, default: 7
      t.integer :digest_minute, null: false, default: 0
      t.boolean :digest_enabled, null: false, default: true
      t.date :digest_last_sent_on
      t.datetime :paused_at
      t.datetime :unsubscribed_at
      t.integer :quiet_hours_start_minute
      t.integer :quiet_hours_end_minute
      t.timestamps
    end
    add_index :subscribers, :email, unique: true

    create_table :station_watches do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.references :monitoring_location, null: false, foreign_key: true
      t.string :label
      t.timestamps
    end
    add_index :station_watches, [ :subscriber_id, :monitoring_location_id ], unique: true, name: "index_station_watches_on_subscriber_and_location"

    create_table :alert_rules do |t|
      t.references :station_watch, null: false, foreign_key: true
      t.string :kind, null: false
      t.boolean :enabled, null: false, default: true
      t.jsonb :params, null: false, default: {}
      t.datetime :last_fired_at
      t.boolean :armed, null: false, default: true
      t.timestamps
    end
    add_index :alert_rules, [ :station_watch_id, :kind ]

    create_table :alert_events do |t|
      t.references :monitoring_location, null: false, foreign_key: true
      t.string :kind, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :dedupe_key, null: false
      t.timestamps
    end
    add_index :alert_events, :dedupe_key, unique: true
    add_index :alert_events, [ :monitoring_location_id, :occurred_at ]

    create_table :alert_deliveries do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.references :alert_event, foreign_key: true
      t.references :alert_rule, foreign_key: true
      t.string :mailer_action, null: false
      t.string :status, null: false, default: "queued"
      t.datetime :sent_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :alert_deliveries, [ :subscriber_id, :created_at ]

    create_table :subscriber_tokens do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at
      t.datetime :used_at
      t.timestamps
    end
    add_index :subscriber_tokens, :token_digest, unique: true
    add_index :subscriber_tokens, [ :subscriber_id, :purpose ]
  end
end
