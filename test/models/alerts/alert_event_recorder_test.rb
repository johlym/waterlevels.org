# frozen_string_literal: true

require "test_helper"

class AlertEventRecorderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @location = create(:monitoring_location)
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
  end

  teardown do
    if @previous_alerts
      ENV["ALERTS_ENABLED"] = @previous_alerts
    else
      ENV.delete("ALERTS_ENABLED")
    end
  end

  test "records flood category change and enqueues evaluation" do
    at = Time.zone.parse("2026-08-29T12:00:00Z")

    event = nil
    assert_enqueued_jobs 1, only: AlertEvaluationJob do
      event = AlertEventRecorder.flood_category_change!(
        location: @location,
        from: "no_flooding",
        to: "major",
        observed_at: at
      )
      assert_equal "flood_category_change", event.kind
      assert_equal "flood:#{@location.id}:no_flooding:major:#{at.to_i}", event.dedupe_key
      assert_equal "major", event.payload["to"]
    end
    assert_enqueued_with(job: AlertEvaluationJob, args: [ @location.id, event.id ])
  end

  test "skips flood record when from and to normalize equal" do
    assert_no_difference("AlertEvent.count") do
      assert_nil AlertEventRecorder.flood_category_change!(
        location: @location,
        from: nil,
        to: "no_flooding",
        observed_at: Time.current
      )
    end
  end

  test "records reading change when values differ" do
    at = Time.zone.parse("2026-08-29T13:00:00Z")
    event = AlertEventRecorder.reading_change!(
      location: @location,
      parameter: "water_level",
      from: 10.1,
      to: 12.4,
      unit: "ft",
      observed_at: at
    )
    assert_equal "reading_change", event.kind
    assert_equal "reading:#{@location.id}:water_level:#{at.to_i}", event.dedupe_key
    assert_equal "12.4", event.payload["to"].to_s
  end

  test "skips reading change when values are equal" do
    assert_no_difference("AlertEvent.count") do
      assert_nil AlertEventRecorder.reading_change!(
        location: @location,
        parameter: "discharge",
        from: 100,
        to: 100,
        unit: "ft3/s",
        observed_at: Time.current
      )
    end
  end

  test "dedupes identical flood events" do
    at = Time.zone.parse("2026-08-29T14:00:00Z")
    first = AlertEventRecorder.flood_category_change!(
      location: @location, from: "action", to: "minor", observed_at: at
    )
    second = AlertEventRecorder.flood_category_change!(
      location: @location, from: "action", to: "minor", observed_at: at
    )
    assert_equal first.id, second.id
    assert_equal 1, AlertEvent.where(monitoring_location: @location).count
  end

  test "does not enqueue evaluation when alerts disabled" do
    ENV["ALERTS_ENABLED"] = "0"
    assert_no_enqueued_jobs(only: AlertEvaluationJob) do
      AlertEventRecorder.flood_category_change!(
        location: @location,
        from: "action",
        to: "major",
        observed_at: Time.current
      )
    end
    assert_equal 1, AlertEvent.count
  end
end
