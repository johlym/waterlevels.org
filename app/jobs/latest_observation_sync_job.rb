class LatestObservationSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    progress = SyncProgress.new("LatestObservationSyncJob", io: nil)
    LatestObservationSync.new(state: state, progress: progress).perform
  end
end
