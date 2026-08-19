class DailyArchiveDrainJob < ApplicationJob
  queue_as :default

  def perform
    unless AppConfig.boolean?(:daily_archive_drain_enabled)
      Rails.logger.info("DailyArchiveDrainJob skipped: disabled by admin settings")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    return unless DailyArchive.configured?
    return unless DailyArchive.prune_enabled?

    progress = SyncProgress.new("DailyArchiveDrainJob", io: nil)
    Telemetry.in_span(
      "daily_archive.drain",
      attributes: { "app.operation" => "daily_archive.drain" }
    ) do
      result = DailyArchive::Drain.new(progress: progress).perform
      vacuum = DailyArchive::TableMaintenance.vacuum_after_deletes!(
        daily_deleted: result[:deleted],
        progress: progress
      )
      Telemetry.add_attributes(
        "app.daily_deleted" => result[:deleted],
        "app.daily_prune_blocked" => result[:blocked],
        "app.vacuumed" => vacuum[:vacuumed]
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
