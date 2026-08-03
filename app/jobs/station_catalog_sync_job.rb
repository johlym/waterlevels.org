class StationCatalogSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    if Usgs::RateLimitCircuit.open?
      Rails.logger.warn("StationCatalogSyncJob skipped: USGS rate limit circuit open")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    progress = SyncProgress.new("StationCatalogSyncJob", io: nil)
    StationCatalogSync.new(state: state, progress: progress).perform
  end
end
