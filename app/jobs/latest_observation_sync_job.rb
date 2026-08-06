class LatestObservationSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    if Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY)
      Rails.logger.warn("LatestObservationSyncJob skipped: USGS tip rate limit circuit open")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    progress = SyncProgress.new("LatestObservationSyncJob", io: nil)
    LatestObservationSync.new(state: state, progress: progress).perform
  end
end
