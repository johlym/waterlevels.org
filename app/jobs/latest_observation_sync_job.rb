class LatestObservationSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    Telemetry.in_span(
      "job.latest_sync",
      attributes: { "usgs.state" => state.presence || "national" }
    ) do
      if Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY)
        Telemetry.add_attributes("skip.reason" => "usgs_circuit_open")
        Rails.logger.warn("LatestObservationSyncJob skipped: USGS tip rate limit circuit open")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("skip.reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      progress = SyncProgress.new("LatestObservationSyncJob", io: nil)
      LatestObservationSync.new(state: state, progress: progress).perform
    end
  end
end
