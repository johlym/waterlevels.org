class StationCatalogSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    progress = SyncProgress.new("StationCatalogSyncJob", io: nil)
    StationCatalogSync.new(state: state, progress: progress).perform
  end
end
