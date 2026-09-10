class DailyArchiveExportJob < ApplicationJob
  queue_as :backfill

  def perform(time_series_ids: nil, only_cold: false)
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    return unless DailyArchive.configured?
    unless DailyArchiveExportLock.claim!
      Rails.logger.info("DailyArchiveExportJob skipped: lock held")
      return
    end

    begin
      progress = SyncProgress.new("DailyArchiveExportJob", io: nil)
      result = DailyArchive::Exporter.new(progress: progress).perform(
        time_series_ids: time_series_ids,
        only_cold: only_cold
      )
      AdminDashboardStats.record_job_finish!(
        :daily_archive_export,
        series: result[:series],
        points: result[:points],
        daily_deleted: result[:daily_deleted],
        vacuumed: result[:vacuumed],
        vacuum_ms: result[:vacuum_ms]
      )
      AdminDashboardStats.schedule_inventory_refresh!
      progress.finish(
        "series=#{result[:series]} points=#{result[:points]} " \
        "daily_deleted=#{result[:daily_deleted]} vacuumed=#{result[:vacuumed]}"
      )
    ensure
      DailyArchiveExportLock.release!
    end
  end
end
