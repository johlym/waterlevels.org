class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    progress = SyncProgress.new("FloodStageSyncJob", io: nil)
    FloodStageSync.new(state: state, progress: progress).perform
  end
end
