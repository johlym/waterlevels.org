class StationCatalogSyncJob < ApplicationJob
  queue_as :sync

  def perform
    StationCatalogSync.new.perform
  end
end
