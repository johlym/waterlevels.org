class NetworkRefreshBatchJob < ApplicationJob
  extend SingletonRunEnqueue
  queue_as :sync
  reserve_singleton_slot NetworkRefreshBatchLock

  def perform(limit = nil, progress: nil)
    Telemetry.work("network_refresh", provider: "usgs") do
      unless AppConfig.boolean?(:nldi_refresh_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("NetworkRefreshBatchJob skipped: disabled by admin settings")
        NetworkRefreshBatchLock.release!(owner: job_id)
        return 0
      end
      if HistoryBackfillJob.paused_for_catalog_sync?
        Telemetry.skip!("sunday_catalog_sync")
        Rails.logger.info("NetworkRefreshBatchJob skipped: Sunday catalog sync window")
        NetworkRefreshBatchLock.release!(owner: job_id)
        return 0
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      if Nldi::RateLimitCircuit.open?
        Telemetry.skip!("nldi_rate_limit")
        Rails.logger.info("NetworkRefreshBatchJob skipped: NLDI rate limit circuit open")
        NetworkRefreshBatchLock.release!(owner: job_id)
        return 0
      end

      budget = station_budget(limit)
      if budget <= 0
        Telemetry.skip!("batch_disabled")
        Telemetry.note(items: 0)
        NetworkRefreshBatchLock.release!(owner: job_id)
        return 0
      end

      unless NetworkRefreshBatchLock.renew!(job_id) || NetworkRefreshBatchLock.claim!(owner: job_id)
        Telemetry.skip!("batch_lock_held")
        Rails.logger.info("NetworkRefreshBatchJob skipped: batch lock held")
        return 0
      end

      begin
        progress ||= SyncProgress.new("NetworkRefreshBatchJob", io: nil, every: 1)
        refreshed = NetworkStations.refresh(
          MonitoringLocation.usgs.order(:id),
          limit: budget,
          progress: progress,
          heartbeat: -> { NetworkRefreshBatchLock.renew!(job_id) }
        )
        Telemetry.note(items: refreshed, budget: budget)
        progress.finish("refreshed=#{refreshed} budget=#{budget}")
        refreshed
      ensure
        NetworkRefreshBatchLock.release!(owner: job_id)
      end
    end
  end

  private

  def station_budget(limit)
    return limit.to_i unless limit.nil?

    AppConfig.integer(:nldi_refresh_batch)
  end
end
