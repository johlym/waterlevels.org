class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  def self.enqueue(monitoring_location_id, range = "7d")
    return false unless HistoryBackfillLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id, range)
    true
  end

  def perform(monitoring_location_id, range = "7d")
    location = MonitoringLocation.find(monitoring_location_id)
    progress = SyncProgress.new("HistoryBackfillJob##{location.site_number}", io: nil)
    HistoryIngestion.new(monitoring_location: location, range: range, progress: progress).perform
  end
end
