class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    Telemetry.work("continuous_prune") do
      unless AppConfig.boolean?(:continuous_prune_enabled)
        Telemetry.skip!("disabled_by_settings")
        Rails.logger.info("ContinuousPruneJob skipped: disabled by admin settings")
        AdminDashboardStats.record_job_progress!(:prune, skip_reason: "disabled_by_settings")
        return
      end
      if DatabaseReadOnlyCircuit.open?
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      unless ContinuousPruneLock.claim!
        Telemetry.skip!("lock_held")
        Rails.logger.info("ContinuousPruneJob skipped: lock held")
        return
      end

      begin
        perform_retention
      ensure
        ContinuousPruneLock.release!(owner: ContinuousPruneLock.default_owner)
      end
    end
  end

  def perform_retention
    progress = SyncProgress.new("ContinuousPruneJob", io: nil)
    readings_deleted = AlertEvent.prune_reading_changes!
    progress.step("reading_change pruned=#{readings_deleted}")
    AdminDashboardStats.record_job_progress!(:prune, phase: "running", reset: true)
    stats = DailyArchive::Retention.new(
      progress: progress,
      heartbeat: -> { ContinuousPruneLock.renew!(ContinuousPruneLock.default_owner) },
      on_phase: ->(phase, phase_stats) {
        ContinuousPruneLock.renew!(ContinuousPruneLock.default_owner)
        AdminDashboardStats.record_job_progress!(:prune, phase: phase, **phase_stats)
      }
    ).perform
    Telemetry.note(
      usgs_ensured: stats[:usgs_ensured],
      derived: stats[:derived],
      retrying: stats[:retrying],
      gaps_alerted: stats[:gaps_alerted],
      iv_deleted: stats[:iv_deleted],
      expired_iv_deleted: stats[:expired_iv_deleted],
      readings_deleted: readings_deleted,
      iv_prune_blocked: stats[:iv_prune_blocked],
      daily_deleted: stats[:daily_deleted],
      daily_prune_blocked: stats[:daily_prune_blocked],
      vacuumed: stats[:vacuumed],
      rows_written: stats[:iv_deleted].to_i + stats[:daily_deleted].to_i
    )
    AdminDashboardStats.record_job_finish!(
      :prune,
      phase: "complete",
      usgs_ensured: stats[:usgs_ensured],
      derived: stats[:derived],
      retrying: stats[:retrying],
      gaps_alerted: stats[:gaps_alerted],
      iv_deleted: stats[:iv_deleted],
      expired_iv_deleted: stats[:expired_iv_deleted],
      readings_deleted: readings_deleted,
      iv_prune_blocked: stats[:iv_prune_blocked],
      daily_deleted: stats[:daily_deleted],
      daily_prune_blocked: stats[:daily_prune_blocked],
      continuous_deleted: stats[:continuous_deleted],
      rolled_up: stats[:rolled_up],
      rollup_skipped: stats[:rollup_skipped],
      vacuumed: stats[:vacuumed],
      vacuum_ms: stats[:vacuum_ms]
    )
    AdminDashboardStats.schedule_inventory_refresh!
    progress.finish(
      "usgs_ensured=#{stats[:usgs_ensured]} derived=#{stats[:derived]} " \
      "retrying=#{stats[:retrying]} gaps_alerted=#{stats[:gaps_alerted]} " \
      "iv_deleted=#{stats[:iv_deleted]} expired_iv=#{stats[:expired_iv_deleted]} " \
      "readings_deleted=#{readings_deleted} iv_blocked=#{stats[:iv_prune_blocked]} " \
      "daily_deleted=#{stats[:daily_deleted]} daily_blocked=#{stats[:daily_prune_blocked]} " \
      "vacuumed=#{stats[:vacuumed]}"
    )
  end
end
