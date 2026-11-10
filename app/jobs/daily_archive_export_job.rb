class DailyArchiveExportJob < ApplicationJob
  queue_as :backfill

  def perform(time_series_ids: nil, only_cold: false)
    Telemetry.work("daily_archive_export") do
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      unless DailyArchive.configured?
        Telemetry.skip!("not_configured")
        Rails.logger.info("DailyArchiveExportJob skipped: archive store not configured")
        AdminDashboardStats.record_job_progress!(
          :daily_archive_export,
          skip_reason: "not_configured"
        )
        return
      end
      unless DailyArchiveExportLock.claim!
        Telemetry.skip!("lock_held")
        Rails.logger.info("DailyArchiveExportJob skipped: lock held")
        AdminDashboardStats.record_job_progress!(
          :daily_archive_export,
          skip_reason: "lock_held"
        )
        return
      end

      begin
        progress = SyncProgress.new("DailyArchiveExportJob", io: nil)
        AdminDashboardStats.record_job_progress!(:daily_archive_export, phase: "running")
        result = DailyArchive::Exporter.new(
          progress: progress,
          heartbeat: -> { DailyArchiveExportLock.renew!(DailyArchiveExportLock.default_owner) }
        ).perform(
          time_series_ids: time_series_ids,
          only_cold: only_cold
        )
        Telemetry.note(
          items: result[:series],
          rows_written: result[:points],
          daily_deleted: result[:daily_deleted],
          vacuumed: result[:vacuumed],
          "phase.vacuum_ms" => result[:vacuum_ms]
        )
        self.class.record_finish!(result)
        AdminDashboardStats.schedule_inventory_refresh!
        progress.finish(
          "series=#{result[:series]} points=#{result[:points]} " \
          "daily_deleted=#{result[:daily_deleted]} vacuumed=#{result[:vacuumed]}"
        )
      ensure
        DailyArchiveExportLock.release!(owner: DailyArchiveExportLock.default_owner)
      end
    end
  end

  def self.record_finish!(result, **extra)
    AdminDashboardStats.record_job_finish!(
      :daily_archive_export,
      phase: "complete",
      series: result[:series],
      points: result[:points],
      daily_deleted: result[:daily_deleted],
      vacuumed: result[:vacuumed],
      vacuum_ms: result[:vacuum_ms],
      **extra
    )
  end
end
