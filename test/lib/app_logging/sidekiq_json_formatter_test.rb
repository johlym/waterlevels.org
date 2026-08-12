require "test_helper"

class AppLoggingSidekiqJsonFormatterTest < ActiveSupport::TestCase
  setup do
    @formatter = AppLogging::SidekiqJsonFormatter.new
  end

  test "formats job done lines with flattened context" do
    line = Sidekiq::Context.with(class: "EdgeCachePurgeJob", jid: "ad101a6ba4f126502ff83632", elapsed: 0.003) do
      @formatter.call("INFO", Time.utc(2026, 8, 12, 22, 17, 53), nil, "done")
    end
    data = JSON.parse(line)

    assert_equal "info", data["level"]
    assert_equal "sidekiq.job", data["event"]
    assert_equal "done", data["message"]
    assert_equal "done", data["status"]
    assert_equal "EdgeCachePurgeJob", data["job"]
    assert_equal "ad101a6ba4f126502ff83632", data["jid"]
    assert_in_delta 0.003, data["elapsed"]
    assert data["pid"]
    assert data["tid"]
  end

  test "formats scheduler queueing lines" do
    line = @formatter.call(
      "INFO",
      Time.utc(2026, 8, 12, 22, 18, 0),
      nil,
      "queueing AdminDashboardCountersJob (admin_dashboard_counters)"
    )
    data = JSON.parse(line)

    assert_equal "sidekiq.enqueue", data["event"]
    assert_equal "AdminDashboardCountersJob", data["job"]
    assert_equal "admin_dashboard_counters", data["schedule"]
    assert_equal "queueing AdminDashboardCountersJob (admin_dashboard_counters)", data["message"]
  end
end
