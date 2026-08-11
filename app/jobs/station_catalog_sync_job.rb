class StationCatalogSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    unless AppConfig.boolean?(:station_catalog_sync_enabled)
      Rails.logger.info("StationCatalogSyncJob skipped: disabled by admin settings")
      return
    end
    if Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY)
      Rails.logger.warn("StationCatalogSyncJob skipped: USGS tip rate limit circuit open")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    progress = SyncProgress.new("StationCatalogSyncJob", io: nil)
    StationCatalogSync.new(state: state, progress: progress).perform
  end
end
