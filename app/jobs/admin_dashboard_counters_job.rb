# Materializes expensive /admin inventory aggregates into AdminCounter rows so
# dashboard section requests do not recompute backfill coverage on the web dyno.
# Also emits the Honeycomb queue, pressure, and coverage gauges. Queue depth is
# cheap and still recorded when the heavy inventory refresh is disabled.
class AdminDashboardCountersJob < ApplicationJob
  queue_as :default

  def perform
    PipelineSignals.record_queues!
    unless AppConfig.boolean?(:admin_dashboard_counters_enabled)
      Rails.logger.info("AdminDashboardCountersJob skipped: disabled by admin settings")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    Telemetry.work("admin_dashboard_counters") do
      aggregates = AdminDashboardStats.refresh_inventory_counters!(source: "schedule")
      PipelineSignals.record_coverage!(aggregates)
      Telemetry.note(
        items: aggregates[:station_count].to_i,
        stations_needing_history: aggregates[:stations_needing_history].to_i,
        stations_needing_deep: aggregates[:stations_needing_deep_history].to_i
      )
      aggregates
    end
  ensure
    AdminDashboardStats.clear_counters_enqueue_lock!
  end
end
