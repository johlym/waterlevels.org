class CdecReservoirSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.in_root_span(
      "job.cdec_reservoir_sync",
      attributes: { "app.operation" => "job.cdec_reservoir_sync" }
    ) do
      progress = SyncProgress.new("CdecReservoirSyncJob", io: nil, every: 1)
      count = CdecReservoirSync.new(progress: progress).perform
      Cdec::ReservoirCatalog.active_entries.each do |entry|
        location = MonitoringLocation.find_by(site_number: entry.site_number)
        next unless location

        CdecHistoryIngestion.new(progress: progress).ingest_recent_tip!(location)
      end
      Telemetry.add_attributes("app.batch_size" => count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
