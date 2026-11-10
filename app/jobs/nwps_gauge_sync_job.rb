class NwpsGaugeSyncJob < ApplicationJob
  queue_as :sync

  def perform
    Telemetry.work("nwps_sync", provider: "nwps") do
      progress = SyncProgress.new("NwpsGaugeSyncJob", io: nil, every: 1)
      count = NwpsGaugeSync.new(progress: progress).perform
      Telemetry.note(items: count)
      progress.finish("synced=#{count}")
      count
    end
  end
end
