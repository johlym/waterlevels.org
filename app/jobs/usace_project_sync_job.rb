class UsaceProjectSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.in_root_span(
      "job.usace_project_sync",
      attributes: { "app.operation" => "job.usace_project_sync" }
    ) do
      progress = SyncProgress.new("UsaceProjectSyncJob", io: nil, every: 1)
      count = UsaceProjectSync.new(progress: progress).perform
      Usace::ProjectCatalog.active_entries.each do |entry|
        location = MonitoringLocation.find_by(site_number: entry.site_number)
        next unless location

        UsaceHistoryIngestion.new(progress: progress).ingest_recent_tip!(location)
      end
      Telemetry.add_attributes("app.batch_size" => count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
