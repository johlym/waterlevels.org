# Materializes expensive /admin inventory aggregates into AdminCounter rows so
# dashboard section requests do not recompute backfill coverage on the web dyno.
class AdminDashboardCountersJob < ApplicationJob
  queue_as :default

  def perform
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    Telemetry.in_root_span(
      "job.admin_dashboard_counters",
      attributes: { "app.operation" => "job.admin_dashboard_counters" }
    ) do
      aggregates = AdminDashboardStats.refresh_inventory_counters!(source: "schedule")
      Telemetry.add_attributes(
        "app.stations_count" => aggregates[:station_count].to_i,
        "app.stations_needing_history" => aggregates[:stations_needing_history].to_i,
        "app.stations_needing_deep_history" => aggregates[:stations_needing_deep_history].to_i
      )
      aggregates
    end
  end
end
