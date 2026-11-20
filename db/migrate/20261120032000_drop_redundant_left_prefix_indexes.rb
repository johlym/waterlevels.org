# frozen_string_literal: true

class DropRedundantLeftPrefixIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # t.references indexes that are a left prefix of a composite on the same table.
  PREFIXES = [
    [ :alert_deliveries, :subscriber_id, "index_alert_deliveries_on_subscriber_id" ],
    [ :alert_events, :monitoring_location_id, "index_alert_events_on_monitoring_location_id" ],
    [ :alert_rules, :station_watch_id, "index_alert_rules_on_station_watch_id" ],
    [ :station_watches, :subscriber_id, "index_station_watches_on_subscriber_id" ],
    [ :subscriber_tokens, :subscriber_id, "index_subscriber_tokens_on_subscriber_id" ]
  ].freeze

  def up
    PREFIXES.each do |table, _column, name|
      remove_index table, name: name, algorithm: :concurrently, if_exists: true
    end
  end

  def down
    PREFIXES.each do |table, column, name|
      add_index table, column,
                name: name,
                algorithm: :concurrently,
                if_not_exists: true
    end
  end
end
