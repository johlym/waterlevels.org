class DailyArchiveDrainJob < ApplicationJob
  queue_as :default

  def perform
    Telemetry.work("daily_archive_drain") do
      unless AppConfig.boolean?(:daily_archive_drain_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("DailyArchiveDrainJob skipped: disabled by admin settings")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      unless DailyArchive.configured?
        Telemetry.skip!("not_configured")
        return
      end
      unless DailyArchive.prune_enabled?
        Telemetry.skip!("prune_disabled")
        return
      end

      progress = SyncProgress.new("DailyArchiveDrainJob", io: nil)
      result = DailyArchive::Drain.new(progress: progress).perform
      vacuum = DailyArchive::TableMaintenance.vacuum_after_deletes!(
        daily_deleted: result[:deleted],
        progress: progress
      )
      Telemetry.note(
        rows_written: result[:deleted],
        daily_deleted: result[:deleted],
        daily_prune_blocked: result[:blocked],
        vacuumed: vacuum[:vacuumed],
        "phase.vacuum_ms" => vacuum[:duration_ms]
      )
      AdminDashboardStats.record_job_finish!(
        :daily_archive_drain,
        daily_deleted: result[:deleted],
        daily_blocked: result[:blocked],
        vacuumed: vacuum[:vacuumed],
        vacuum_ms: vacuum[:duration_ms]
      )
      AdminDashboardStats.schedule_inventory_refresh!
      progress.finish(
        "daily_deleted=#{result[:deleted]} daily_blocked=#{result[:blocked]} " \
        "vacuumed=#{vacuum[:vacuumed]}"
      )
    end
  end
end
