class UsbrReservoirSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.work("usbr_sync", provider: "usbr") do
      progress = SyncProgress.new("UsbrReservoirSyncJob", io: nil, every: 1)
      count = UsbrReservoirSync.new(progress: progress).perform
      # Keep a short recent daily window warm in the archive for 30d charts.
      Usbr::ReservoirCatalog.active_entries.each do |entry|
        location = MonitoringLocation.find_by(site_number: entry.site_number)
        next unless location

        UsbrHistoryIngestion.new(progress: progress).ingest_recent_tip!(location)
      end
      Telemetry.note(items: count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
