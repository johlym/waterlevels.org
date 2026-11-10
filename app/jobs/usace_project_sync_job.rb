class UsaceProjectSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.work("usace_sync", provider: "usace") do
      progress = SyncProgress.new("UsaceProjectSyncJob", io: nil, every: 1)
      count = UsaceProjectSync.new(progress: progress).perform
      Usace::ProjectCatalog.active_entries.each do |entry|
        location = MonitoringLocation.find_by(site_number: entry.site_number)
        next unless location

        UsaceHistoryIngestion.new(progress: progress).ingest_recent_tip!(location)
      end
      Telemetry.note(items: count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
