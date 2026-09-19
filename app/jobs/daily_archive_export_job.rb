class DailyArchiveExportJob < ApplicationJob
  queue_as :backfill

  def perform(time_series_ids: nil, only_cold: false)
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    unless DailyArchive.configured?
      Rails.logger.info("DailyArchiveExportJob skipped: archive store not configured")
      AdminDashboardStats.record_job_progress!(
        :daily_archive_export,
        skip_reason: "not_configured"
      )
      return
    end
    unless DailyArchiveExportLock.claim!
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
      result = DailyArchive::Exporter.new(progress: progress).perform(
        time_series_ids: time_series_ids,
        only_cold: only_cold
      )
      self.class.record_finish!(result)
      AdminDashboardStats.schedule_inventory_refresh!
      progress.finish(
        "series=#{result[:series]} points=#{result[:points]} " \
        "daily_deleted=#{result[:daily_deleted]} vacuumed=#{result[:vacuumed]}"
      )
    ensure
      DailyArchiveExportLock.release!
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
