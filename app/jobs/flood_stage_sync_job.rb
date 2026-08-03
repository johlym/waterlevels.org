class FloodStageSyncJob < ApplicationJob
  queue_as :sync

  def perform(state = nil)
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    progress = SyncProgress.new("FloodStageSyncJob", io: nil)
    FloodStageSync.new(state: state, progress: progress).perform
  end
end
