# frozen_string_literal: true

require "test_helper"

class AlertEventTest < ActiveSupport::TestCase
  setup do
    @location = create(:monitoring_location)
  end

  test "prune_reading_changes drops old reading rows and keeps the rest" do
    old_reading = create(
      :alert_event,
      monitoring_location: @location,
      kind: "reading_change",
      occurred_at: 8.days.ago,
      dedupe_key: "reading:old"
    )
    recent_reading = create(
      :alert_event,
      monitoring_location: @location,
      kind: "reading_change",
      occurred_at: 1.hour.ago,
      dedupe_key: "reading:recent"
    )
    flood = create(
      :alert_event,
      monitoring_location: @location,
      kind: "flood_category_change",
      occurred_at: 30.days.ago,
      dedupe_key: "flood:old"
    )
    delivery = create(:alert_delivery, alert_event: old_reading, subscriber: create(:subscriber, :verified))

    deleted = AlertEvent.prune_reading_changes!

    assert_equal 1, deleted
    assert_nil AlertEvent.find_by(id: old_reading.id)
    assert AlertEvent.exists?(recent_reading.id)
    assert AlertEvent.exists?(flood.id)
    assert_nil delivery.reload.alert_event_id
  end
end
