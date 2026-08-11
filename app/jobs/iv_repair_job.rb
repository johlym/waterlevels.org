class IvRepairJob < ApplicationJob
  queue_as :iv_repair

  def self.paused_for_catalog_sync?(time = Time.current)
    HistoryBackfillJob.paused_for_catalog_sync?(time)
  end

  def self.enqueue(monitoring_location_id)
    return false if paused_for_catalog_sync?
    return false unless Usgs::HistoryKeyPool.iv_repair_available?
    return false if DatabaseReadOnlyCircuit.open?
    return false unless IvRepairLock.claim!(monitoring_location_id)

    perform_later(monitoring_location_id)
    true
  end

  def perform(monitoring_location_id)
    Telemetry.in_span(
      "job.iv_repair",
      attributes: {
        "app.operation" => "job.iv_repair",
        "app.monitoring_location_id" => monitoring_location_id
      }
    ) do
      if self.class.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("IvRepairJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
        return
      end
      unless Usgs::HistoryKeyPool.iv_repair_available?
        Telemetry.add_attributes("app.skip_reason" => "iv_repair_key_unavailable")
        Rails.logger.info("IvRepairJob skipped: IV repair rate limit circuit open id=#{monitoring_location_id}")
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
      progress = SyncProgress.new("IvRepairJob##{location.site_number}", io: nil)
      HistoryIngestion.new(
        monitoring_location: location,
        range: HistoryIngestion::DEFAULT_RANGE,
        mode: HistoryIngestion::MODE_IV_REPAIR,
        progress: progress
      ).perform

      still_needs = location.needs_iv_repair?
      Telemetry.add_attributes("app.still_needs_iv_repair" => still_needs)
      if still_needs
        IvRepairLock.cooldown!(monitoring_location_id)
        Rails.logger.info(
          "IvRepairJob cooldown site=#{location.site_number} still_needs_iv_repair=true"
        )
      end
    end
  ensure
    IvRepairLock.release!(monitoring_location_id)
  end
end
