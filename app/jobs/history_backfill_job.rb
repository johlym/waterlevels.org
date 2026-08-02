class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  def self.enqueue(monitoring_location_id, range = "7d")
    return false unless HistoryBackfillLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id, range)
    true
  end

  def perform(monitoring_location_id, range = "7d")
    location = nil
    location = MonitoringLocation.find(monitoring_location_id)
    progress = SyncProgress.new("HistoryBackfillJob##{location.site_number}", io: nil)
    HistoryIngestion.new(monitoring_location: location, range: range, progress: progress).perform
  ensure
    HistoryBackfillLock.release!(monitoring_location_id)
    # Stations with selected series that USGS never returns continuous for would
    # otherwise monopolize ORDER BY id LIMIT N every hour.
    if location&.needs_history_backfill?
      HistoryBackfillLock.cooldown!(monitoring_location_id)
      Rails.logger.info(
        "HistoryBackfillJob cooldown site=#{location.site_number} still_needs_backfill=true"
      )
    end
  end
end
