class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  # Sunday national catalog sync competes for the USGS hourly request budget.
  def self.paused_for_catalog_sync?(time = Time.current)
    time.in_time_zone.sunday?
  end

  def self.enqueue(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    return false if paused_for_catalog_sync?
    return false if Usgs::HistoryKeyPool.exhausted?
    return false if DatabaseReadOnlyCircuit.open?
    return false unless HistoryBackfillLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id, range)
    true
  end

  def perform(monitoring_location_id, range = HistoryIngestion::DEFAULT_RANGE)
    Telemetry.in_span(
      "job.history_backfill",
      attributes: {
        "app.operation" => "job.history_backfill",
        "app.monitoring_location_id" => monitoring_location_id,
        "app.range" => range.to_s
      }
    ) do
      if self.class.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("HistoryBackfillJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
        return
      end
      if Usgs::HistoryKeyPool.exhausted?
        Telemetry.add_attributes("app.skip_reason" => "history_keys_exhausted")
        Rails.logger.info("HistoryBackfillJob skipped: USGS history rate limit circuits open id=#{monitoring_location_id}")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open id=#{monitoring_location_id}"
      end

      location = MonitoringLocation.find(monitoring_location_id)
      Telemetry.add_attributes(
        "app.site_number" => location.site_number,
        "app.state" => location.state_code,
        "app.location_name" => location.display_name
      )
      progress = SyncProgress.new("HistoryBackfillJob##{location.site_number}", io: nil)
      # HistoryIngestion opens its own root span (linked here) so the big ingest
      # trace always has a root even if this job wrapper fails to export.
      HistoryIngestion.new(monitoring_location: location, range: range, progress: progress).perform

      # Only cooldown after a successful attempt that still left gaps. Failed
      # writes (e.g. read-only DB) must not park the station for 6 hours.
      still_needs = location.needs_history_backfill? ||
        (range.to_s == HistoryIngestion::DEEP_RANGE && location.missing_deep_history?)
      Telemetry.add_attributes("app.still_needs_backfill" => still_needs)
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
