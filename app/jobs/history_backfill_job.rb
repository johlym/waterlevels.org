class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  # Sunday national catalog sync competes for the USGS hourly request budget.
  def self.paused_for_catalog_sync?(time = Time.current)
    return false unless AppConfig.boolean?(:sunday_catalog_pause_enabled)

    time.in_time_zone.sunday?
  end

  def self.enqueue(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    return false unless AppConfig.boolean?(:history_backfill_enabled)
    return false if paused_for_catalog_sync?
    return false unless history_keys_available_for?(range)
    return false if DatabaseReadOnlyCircuit.open?
    return false unless HistoryBackfillLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id, range)
    true
  end

  def self.history_keys_available_for?(range)
    if range.to_s == HistoryIngestion::DEEP_RANGE
      Usgs::HistoryKeyPool.deep_available?
    else
      Usgs::HistoryKeyPool.phase1_available?
    end
  end

  def perform(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    Telemetry.work("history_backfill", provider: "usgs", range: range.to_s) do
      unless AppConfig.boolean?(:history_backfill_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("HistoryBackfillJob skipped: disabled by admin settings id=#{monitoring_location_id}")
        return
      end
      if self.class.paused_for_catalog_sync?
        Telemetry.skip!("sunday_catalog_sync")
        Rails.logger.info("HistoryBackfillJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
        return
      end
      unless self.class.history_keys_available_for?(range)
        Telemetry.skip!("history_keys_exhausted")
        Rails.logger.info("HistoryBackfillJob skipped: USGS history rate limit circuits open id=#{monitoring_location_id}")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open id=#{monitoring_location_id}"
      end

      location = MonitoringLocation.find(monitoring_location_id)
      Telemetry.note(site_number: location.site_number, state: location.state_code)
      unless location.usgs?
        Telemetry.skip!("non_usgs_provider")
        Rails.logger.info(
          "HistoryBackfillJob skipped: non-USGS provider id=#{monitoring_location_id} " \
          "provider=#{location.data_provider}"
        )
        return
      end
      progress = SyncProgress.new("HistoryBackfillJob##{location.site_number}", io: nil)
      ingestion = HistoryIngestion.new(monitoring_location: location, range: range, progress: progress)
      ingestion.perform

      # Only cooldown after a successful attempt that still left gaps. Failed
      # writes (e.g. read-only DB) must not park the station for 6 hours.
      still_needs = location.needs_history_backfill? ||
        location.needs_daily_tip_refresh? ||
        (range.to_s == HistoryIngestion::DEEP_RANGE && location.missing_deep_history?)
      stats = ingestion.last_stats || {}
      Telemetry.note(incomplete: still_needs || stats[:continuous_incomplete])
      if still_needs
        HistoryBackfillLock.cooldown!(monitoring_location_id)
        Rails.logger.info(
          "HistoryBackfillJob cooldown site=#{location.site_number} range=#{range} still_needs_backfill=true"
        )
      end
    end
  ensure
    HistoryBackfillLock.release!(monitoring_location_id)
  end
end
