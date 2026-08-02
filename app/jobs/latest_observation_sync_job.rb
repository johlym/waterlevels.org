class LatestObservationSyncJob < ApplicationJob
  queue_as :sync

  def perform
    LatestObservationSync.new.perform
  end
end
