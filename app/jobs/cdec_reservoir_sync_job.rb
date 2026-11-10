class CdecReservoirSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.work("cdec_sync", provider: "cdec") do
      progress = SyncProgress.new("CdecReservoirSyncJob", io: nil, every: 1)
      count = CdecReservoirSync.new(progress: progress).perform
      Cdec::ReservoirCatalog.active_entries.each do |entry|
        location = MonitoringLocation.find_by(site_number: entry.site_number)
        next unless location

        CdecHistoryIngestion.new(progress: progress).ingest_recent_tip!(location)
      end
      Telemetry.note(items: count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
