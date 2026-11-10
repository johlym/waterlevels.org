class LatestObservationSyncJob < ApplicationJob
  extend SingletonRunEnqueue
  queue_as :sync
  reserve_singleton_slot LatestObservationSyncLock

  # LatestObservationSync holds LatestObservationSyncLock for the whole run so
  # two tip jobs cannot consume both sync_worker threads (concurrency 2).
  #
  # National runs (state omitted) process one USPS state at a time inside
  # LatestObservationSync to keep the 512MB sync worker under the tip-index +
  # USGS page peak. Pass a state for bootstrap / targeted refresh.
  def perform(state = nil)
    Telemetry.work(
      "latest_sync",
      provider: "usgs",
      state: state.presence || "national"
    ) do
      unless AppConfig.boolean?(:latest_observation_sync_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("LatestObservationSyncJob skipped: disabled by admin settings")
        LatestObservationSyncLock.release!(owner: job_id)
        return
      end
      if Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY)
        Telemetry.skip!("usgs_circuit_open")
        Rails.logger.warn("LatestObservationSyncJob skipped: USGS tip rate limit circuit open")
        LatestObservationSyncLock.release!(owner: job_id)
        return
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      progress = SyncProgress.new("LatestObservationSyncJob", io: nil)
      LatestObservationSync.new(state: state, progress: progress).perform(lock_owner: job_id)
    end
  end
end
