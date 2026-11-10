class IvRepairJob < ApplicationJob
  queue_as :iv_repair

  def self.paused_for_catalog_sync?(time = Time.current)
    HistoryBackfillJob.paused_for_catalog_sync?(time)
  end

  # Returns nil when enqueued, or a symbol reason when skipped.
  def self.enqueue_block_reason(monitoring_location_id)
    return :disabled_by_settings unless AppConfig.boolean?(:iv_repair_enabled)
    return :sunday_catalog_sync if paused_for_catalog_sync?
    return :iv_repair_circuit_open unless Usgs::HistoryKeyPool.iv_repair_available?
    return :db_read_only if DatabaseReadOnlyCircuit.open?
    return :locked_or_cooling unless IvRepairLock.claim!(monitoring_location_id)

    nil
  end

  def self.enqueue(monitoring_location_id)
    reason = enqueue_block_reason(monitoring_location_id)
    if reason
      # locked_or_cooling is common on gauge-page retries — keep it quiet.
      if reason == :locked_or_cooling
        Rails.logger.debug { "IvRepairJob enqueue skipped id=#{monitoring_location_id} reason=#{reason}" }
      else
        Rails.logger.info(
          "IvRepairJob enqueue skipped id=#{monitoring_location_id} reason=#{reason}"
        )
      end
      return false
    end

    perform_later(monitoring_location_id)
    Rails.logger.info("IvRepairJob enqueued id=#{monitoring_location_id}")
    true
  end

  def perform(monitoring_location_id)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Telemetry.work(
      "iv_repair",
      provider: "usgs",
      range: HistoryIngestion::DEFAULT_RANGE,
      ingest_mode: HistoryIngestion::MODE_IV_REPAIR
    ) do
      unless AppConfig.boolean?(:iv_repair_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("IvRepairJob skipped: disabled by admin settings id=#{monitoring_location_id}")
        return
      end
      if self.class.paused_for_catalog_sync?
        Telemetry.skip!("sunday_catalog_sync")
        Rails.logger.info("IvRepairJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
        return
      end
      unless Usgs::HistoryKeyPool.iv_repair_available?
        Telemetry.skip!("iv_repair_key_unavailable")
        Rails.logger.info(
          "IvRepairJob skipped: IV repair rate limit circuit open id=#{monitoring_location_id} " \
          "circuit=#{Usgs::HistoryKeyPool.circuit_key_for(:iv_repair)}"
        )
        return
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open id=#{monitoring_location_id}"
      end

      location = MonitoringLocation.find(monitoring_location_id)
      Telemetry.note(site_number: location.site_number, state: location.state_code)
      Rails.logger.info(
        "IvRepairJob start id=#{location.id} site=#{location.site_number} " \
        "state=#{location.state_code} name=#{location.display_name.inspect} " \
        "circuit=#{Usgs::HistoryKeyPool.circuit_key_for(:iv_repair)} " \
        "key_configured=#{Usgs::HistoryKeyPool.configured?(:iv_repair)}"
      )

      progress = SyncProgress.new("IvRepairJob##{location.site_number}", io: nil)
      ingestion = HistoryIngestion.new(
        monitoring_location: location,
        range: HistoryIngestion::DEFAULT_RANGE,
        mode: HistoryIngestion::MODE_IV_REPAIR,
        progress: progress
      )
      ingestion.perform
      stats = ingestion.last_stats || {}

      still_needs = location.needs_iv_repair?
      elapsed_s = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      Telemetry.note(
        incomplete: still_needs || stats[:continuous_incomplete],
        rows_written: stats[:continuous_observation_count].to_i,
        items: stats[:continuous_series_count].to_i,
        range_count: stats[:range_count].to_i
      )

      if still_needs
        IvRepairLock.cooldown!(monitoring_location_id)
        Rails.logger.info(
          "IvRepairJob finished site=#{location.site_number} elapsed_s=#{elapsed_s} " \
          "continuous_upserted=#{stats[:continuous_observation_count].to_i} " \
          "series=#{stats[:continuous_series_count].to_i} ranges=#{stats[:range_count].to_i} " \
          "still_needs_iv_repair=true cooldown=#{IvRepairLock::COOLDOWN_TTL.inspect}"
        )
      else
        Rails.logger.info(
          "IvRepairJob finished site=#{location.site_number} elapsed_s=#{elapsed_s} " \
          "continuous_upserted=#{stats[:continuous_observation_count].to_i} " \
          "series=#{stats[:continuous_series_count].to_i} ranges=#{stats[:range_count].to_i} " \
          "still_needs_iv_repair=false"
        )
      end

      AdminDashboardStats.record_job_finish!(
        :iv_repair,
        site_number: location.site_number,
        state: location.state_code,
        continuous_upserted: stats[:continuous_observation_count].to_i,
        series_count: stats[:continuous_series_count].to_i,
        range_count: stats[:range_count].to_i,
        still_needs: still_needs,
        elapsed_s: elapsed_s
      )
    end
  ensure
    IvRepairLock.release!(monitoring_location_id)
  end
end
