class AddUniqueIndexOnAlertDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_index :alert_deliveries,
              [ :subscriber_id, :alert_event_id, :alert_rule_id ],
              unique: true,
              where: "alert_event_id IS NOT NULL AND alert_rule_id IS NOT NULL",
              name: "index_alert_deliveries_unique_event_rule"
  end
end
