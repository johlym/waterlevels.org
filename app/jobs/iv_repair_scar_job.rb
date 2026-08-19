class IvRepairScarJob < ApplicationJob
  queue_as :iv_repair_scar

  def self.paused_for_catalog_sync?(time = Time.current)
    HistoryBackfillJob.paused_for_catalog_sync?(time)
  end

  # Returns nil when enqueued, or a symbol reason when skipped.
  # Shares IvRepairLock with the tip lane so both never fetch the same station.
  def self.enqueue_block_reason(monitoring_location_id)
    return :disabled_by_settings unless AppConfig.boolean?(:iv_scar_enabled)
    return :sunday_catalog_sync if paused_for_catalog_sync?
    return :iv_repair2_key_unconfigured unless Usgs::HistoryKeyPool.configured?(:iv_repair2)
    return :iv_repair2_circuit_open unless Usgs::HistoryKeyPool.iv_repair2_available?
    return :db_read_only if DatabaseReadOnlyCircuit.open?
    return :locked_or_cooling unless IvRepairLock.claim!(monitoring_location_id)

    nil
  end

  def self.enqueue(monitoring_location_id)
    reason = enqueue_block_reason(monitoring_location_id)
    if reason
      if reason == :locked_or_cooling
        Rails.logger.debug { "IvRepairScarJob enqueue skipped id=#{monitoring_location_id} reason=#{reason}" }
      else
        Rails.logger.info(
          "IvRepairScarJob enqueue skipped id=#{monitoring_location_id} reason=#{reason}"
        )
      end
      return false
    end

    perform_later(monitoring_location_id)
    Rails.logger.info("IvRepairScarJob enqueued id=#{monitoring_location_id}")
    true
  end

  def perform(monitoring_location_id)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Telemetry.in_span(
      "job.iv_repair_scar",
      attributes: {
        "app.operation" => "job.iv_repair_scar",
        "app.monitoring_location_id" => monitoring_location_id
      }
    ) do
      unless AppConfig.boolean?(:iv_scar_enabled)
        Telemetry.add_attributes("app.skip_reason" => "disabled_by_settings")
        Rails.logger.info("IvRepairScarJob skipped: disabled by admin settings id=#{monitoring_location_id}")
        return
      end
      if self.class.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("IvRepairScarJob skipped: Sunday catalog sync window id=#{monitoring_location_id}")
        return
      end
      unless Usgs::HistoryKeyPool.configured?(:iv_repair2)
        Telemetry.add_attributes("app.skip_reason" => "iv_repair2_key_unconfigured")
        Rails.logger.info(
          "IvRepairScarJob skipped: USGS_API_HISTORY_IVREPAIR2_KEY unset id=#{monitoring_location_id}"
        )
        return
      end
      unless Usgs::HistoryKeyPool.iv_repair2_available?
        Telemetry.add_attributes("app.skip_reason" => "iv_repair2_key_unavailable")
        Rails.logger.info(
          "IvRepairScarJob skipped: IV scar rate limit circuit open id=#{monitoring_location_id} " \
          "circuit=#{Usgs::HistoryKeyPool.circuit_key_for(:iv_repair2)}"
        )
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
      Rails.logger.info(
        "IvRepairScarJob start id=#{location.id} site=#{location.site_number} " \
        "state=#{location.state_code} name=#{location.display_name.inspect} " \
        "circuit=#{Usgs::HistoryKeyPool.circuit_key_for(:iv_repair2)} " \
        "key_configured=#{Usgs::HistoryKeyPool.configured?(:iv_repair2)}"
      )

      progress = SyncProgress.new("IvRepairScarJob##{location.site_number}", io: nil)
      ingestion = HistoryIngestion.new(
        monitoring_location: location,
        range: HistoryIngestion::DEFAULT_RANGE,
        mode: HistoryIngestion::MODE_IV_REPAIR_SCAR,
        progress: progress
      )
      ingestion.perform
      stats = ingestion.last_stats || {}

      location.time_series.reset
      still_needs = location.needs_iv_scar_repair?
      parked_unfillable = location.known_missing_usgs_iv?
      recheck_at = location.usgs_iv_gap_recheck_at
      elapsed_s = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      Telemetry.add_attributes(
        "app.still_needs_iv_scar_repair" => still_needs,
        "app.parked_unfillable" => parked_unfillable,
        "app.continuous_observation_count" => stats[:continuous_observation_count].to_i,
        "app.continuous_series_count" => stats[:continuous_series_count].to_i,
        "app.range_count" => stats[:range_count].to_i,
        "app.elapsed_s" => elapsed_s
      )

      if still_needs
        IvRepairLock.cooldown!(monitoring_location_id)
        Rails.logger.info(
          "IvRepairScarJob finished site=#{location.site_number} elapsed_s=#{elapsed_s} " \
          "continuous_upserted=#{stats[:continuous_observation_count].to_i} " \
          "series=#{stats[:continuous_series_count].to_i} ranges=#{stats[:range_count].to_i} " \
          "still_needs_iv_scar_repair=true cooldown=#{IvRepairLock::COOLDOWN_TTL.inspect}"
        )
      else
        Rails.logger.info(
          "IvRepairScarJob finished site=#{location.site_number} elapsed_s=#{elapsed_s} " \
          "continuous_upserted=#{stats[:continuous_observation_count].to_i} " \
          "series=#{stats[:continuous_series_count].to_i} ranges=#{stats[:range_count].to_i} " \
          "still_needs_iv_scar_repair=false parked_unfillable=#{parked_unfillable} " \
          "recheck_at=#{recheck_at&.iso8601}"
        )
      end

      AdminDashboardStats.record_job_finish!(
        :iv_repair_scar,
        site_number: location.site_number,
        state: location.state_code,
        continuous_upserted: stats[:continuous_observation_count].to_i,
        series_count: stats[:continuous_series_count].to_i,
        range_count: stats[:range_count].to_i,
        still_needs: still_needs,
        parked_unfillable: parked_unfillable,
        usgs_iv_gap_recheck_at: recheck_at&.iso8601,
        elapsed_s: elapsed_s
      )
    end
  ensure
    IvRepairLock.release!(monitoring_location_id)
  end
end
