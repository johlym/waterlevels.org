class BootstrapStateJob < ApplicationJob
  queue_as :sync

  def perform(state)
    progress = SyncProgress.new("BootstrapStateJob##{state}", io: nil)
    progress.step("catalog")
    StationCatalogSync.new(state: state, progress: progress).perform
    progress.step("latest")
    LatestObservationSync.new(state: state, progress: progress).perform
    progress.finish("state=#{state}")
  end
end
