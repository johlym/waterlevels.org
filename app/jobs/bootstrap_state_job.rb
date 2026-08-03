class BootstrapStateJob < ApplicationJob
  queue_as :sync

  def perform(state)
    if Usgs::RateLimitCircuit.open?
      Rails.logger.warn("BootstrapStateJob skipped: USGS rate limit circuit open state=#{state}")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open state=#{state}"
    end

    progress = SyncProgress.new("BootstrapStateJob##{state}", io: nil)
    progress.step("catalog")
    StationCatalogSync.new(state: state, progress: progress).perform
    progress.step("latest")
    LatestObservationSync.new(state: state, progress: progress).perform
    progress.step("flood_stages")
    FloodStageSync.new(state: state, progress: progress).perform
    progress.finish("state=#{state}")
  end
end
