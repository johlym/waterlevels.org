require "test_helper"

class AdminCounterTest < ActiveSupport::TestCase
  test "set! upserts by name and round-trips nested payload" do
    AdminCounter.set!(
      "admin:test",
      value: 3,
      source: "job",
      finished_at: Time.current.iso8601,
      nested: { rows: [ { state_code: "wa", count: 2 } ] }
    )
    AdminCounter.set!(
      "admin:test",
      value: 9,
      source: "schedule",
      finished_at: 1.hour.ago.iso8601,
      nested: { rows: [ { state_code: "or", count: 4 } ] }
    )

    assert_equal 1, AdminCounter.where(name: "admin:test").count
    row = AdminCounter.fetch("admin:test")
    assert_equal 9, row.value
    assert_equal "schedule", row.source

    payload = AdminCounter.payload_for("admin:test")
    assert_equal "or", payload[:nested][:rows].first[:state_code]
    assert_equal 4, payload[:nested][:rows].first[:count]
  end

  test "clear! removes selected names only" do
    AdminCounter.set!("admin:a", value: 1)
    AdminCounter.set!("admin:b", value: 2)

    AdminCounter.clear!("admin:a")

    assert_nil AdminCounter.fetch("admin:a")
    assert_equal 2, AdminCounter.value_for("admin:b")
  end
end
