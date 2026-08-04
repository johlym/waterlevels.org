class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  # Sunday national catalog sync competes for the USGS hourly request budget.
  def self.paused_for_catalog_sync?(time = Time.current)
    time.in_time_zone.sunday?
  end

  def self.enqueue(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    return false if paused_for_catalog_sync?
    return false if Usgs::RateLimitCircuit.open?
    return false if DatabaseReadOnlyCircuit.open?
    return false unless HistoryBackfillLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id, range)
    true
  end

  def perform(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    if self.class.paused_for_catalog_sync?
      Rails.logger.info("HistoryBackfillJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
      return
    end
    if Usgs::RateLimitCircuit.open?
      Rails.logger.info("HistoryBackfillJob skipped: USGS rate limit circuit open id=#{monitoring_location_id}")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open id=#{monitoring_location_id}"
    end

    location = MonitoringLocation.find(monitoring_location_id)
    progress = SyncProgress.new("HistoryBackfillJob##{location.site_number}", io: nil)
    HistoryIngestion.new(monitoring_location: location, range: range, progress: progress).perform

    # Only cooldown after a successful attempt that still left gaps. Failed
    # writes (e.g. read-only DB) must not park the station for 6 hours.
    still_needs = location.needs_history_backfill? ||
      (range.to_s == HistoryIngestion::DEEP_RANGE && location.missing_deep_history?)
    if still_needs
      HistoryBackfillLock.cooldown!(monitoring_location_id)
      Rails.logger.info(
        "HistoryBackfillJob cooldown site=#{location.site_number} range=#{range} still_needs_backfill=true"
      )
    end
  ensure
    HistoryBackfillLock.release!(monitoring_location_id)
  end
end
