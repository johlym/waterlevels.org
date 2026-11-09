class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    unless AppConfig.boolean?(:continuous_prune_enabled)
      Rails.logger.info("ContinuousPruneJob skipped: disabled by admin settings")
      AdminDashboardStats.record_job_progress!(:prune, skip_reason: "disabled_by_settings")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    unless ContinuousPruneLock.claim!
      Rails.logger.info("ContinuousPruneJob skipped: lock held")
      return
    end

    begin
      perform_retention
    ensure
      ContinuousPruneLock.release!(owner: ContinuousPruneLock.default_owner)
    end
  end

  def perform_retention
    progress = SyncProgress.new("ContinuousPruneJob", io: nil)
    readings_deleted = AlertEvent.prune_reading_changes!
    progress.step("reading_change pruned=#{readings_deleted}")
    Telemetry.in_span(
      "daily_archive.retention",
      attributes: { "app.operation" => "daily_archive.retention" }
    ) do
      AdminDashboardStats.record_job_progress!(:prune, phase: "running", reset: true)
      stats = DailyArchive::Retention.new(
        progress: progress,
        heartbeat: -> { ContinuousPruneLock.renew!(ContinuousPruneLock.default_owner) },
        on_phase: ->(phase, phase_stats) {
          ContinuousPruneLock.renew!(ContinuousPruneLock.default_owner)
          AdminDashboardStats.record_job_progress!(:prune, phase: phase, **phase_stats)
        }
      ).perform
      Telemetry.add_attributes(
        "app.usgs_ensured" => stats[:usgs_ensured],
        "app.derived" => stats[:derived],
        "app.retrying" => stats[:retrying],
        "app.gaps_alerted" => stats[:gaps_alerted],
        "app.iv_deleted" => stats[:iv_deleted],
        "app.expired_iv_deleted" => stats[:expired_iv_deleted],
        "app.readings_deleted" => readings_deleted,
        "app.iv_prune_blocked" => stats[:iv_prune_blocked],
        "app.daily_deleted" => stats[:daily_deleted],
        "app.daily_prune_blocked" => stats[:daily_prune_blocked],
        "app.vacuumed" => stats[:vacuumed]
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
end
