# Weekly integrity rebuild of observation_rollups. Triggers maintain the
# table between runs; this repairs selection changes and any missed delta.
# Scheduled after Sunday's continuous prune.
class ObservationRollupRebuildJob < ApplicationJob
  queue_as :default

  def perform
    Telemetry.work("observation_rollup_rebuild") do
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      ObservationRollup.rebuild!
      AdminDashboardStats.schedule_inventory_refresh!
    end
  end
end
