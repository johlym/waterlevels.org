class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    unless AppConfig.boolean?(:continuous_prune_enabled)
      Rails.logger.info("ContinuousPruneJob skipped: disabled by admin settings")
      return
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    progress = SyncProgress.new("ContinuousPruneJob", io: nil)
    Telemetry.in_span(
      "daily_archive.retention",
      attributes: { "app.operation" => "daily_archive.retention" }
    ) do
      stats = DailyArchive::Retention.new(progress: progress).perform
      Telemetry.add_attributes(
        "app.usgs_ensured" => stats[:usgs_ensured],
        "app.derived" => stats[:derived],
        "app.retrying" => stats[:retrying],
        "app.gaps_alerted" => stats[:gaps_alerted],
        "app.iv_deleted" => stats[:iv_deleted],
        "app.iv_prune_blocked" => stats[:iv_prune_blocked],
        "app.daily_deleted" => stats[:daily_deleted],
        "app.daily_prune_blocked" => stats[:daily_prune_blocked]
      )
      AdminDashboardStats.record_job_finish!(
        :prune,
        usgs_ensured: stats[:usgs_ensured],
        derived: stats[:derived],
        retrying: stats[:retrying],
        gaps_alerted: stats[:gaps_alerted],
        iv_deleted: stats[:iv_deleted],
        iv_prune_blocked: stats[:iv_prune_blocked],
        daily_deleted: stats[:daily_deleted],
        daily_prune_blocked: stats[:daily_prune_blocked],
        continuous_deleted: stats[:continuous_deleted],
        rolled_up: stats[:rolled_up],
        rollup_skipped: stats[:rollup_skipped]
      )
      progress.finish(
        "usgs_ensured=#{stats[:usgs_ensured]} derived=#{stats[:derived]} " \
        "retrying=#{stats[:retrying]} gaps_alerted=#{stats[:gaps_alerted]} " \
        "iv_deleted=#{stats[:iv_deleted]} iv_blocked=#{stats[:iv_prune_blocked]} " \
        "daily_deleted=#{stats[:daily_deleted]} daily_blocked=#{stats[:daily_prune_blocked]}"
      )
    end
  end
end
