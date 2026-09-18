class NwpsGaugeSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.in_root_span(
      "job.nwps_gauge_sync",
      attributes: { "app.operation" => "job.nwps_gauge_sync" }
    ) do
      progress = SyncProgress.new("NwpsGaugeSyncJob", io: nil, every: 1)
      count = NwpsGaugeSync.new(progress: progress).perform
      Telemetry.add_attributes("app.batch_size" => count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
