class LatestObservationSyncJob < ApplicationJob
  queue_as :sync

  # National runs (state omitted) process one USPS state at a time inside
  # LatestObservationSync to keep the 512MB sync worker under the tip-index +
  # USGS page peak. Pass a state for bootstrap / targeted refresh.
  def perform(state = nil)
    Telemetry.in_span(
      "job.latest_sync",
      attributes: {
        "app.operation" => "job.latest_sync",
        "app.state" => state.presence || "national"
      }
    ) do
      if Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY)
        Telemetry.add_attributes("app.skip_reason" => "usgs_circuit_open")
        Rails.logger.warn("LatestObservationSyncJob skipped: USGS tip rate limit circuit open")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      progress = SyncProgress.new("LatestObservationSyncJob", io: nil)
      LatestObservationSync.new(state: state, progress: progress).perform
    end
  end
end
