class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    stats = DailyArchive::Retention.new.perform
    AdminDashboardStats.record_job_finish!(
      :prune,
      continuous_deleted: stats[:continuous_deleted],
      daily_deleted: stats[:daily_deleted],
      rolled_up: stats[:rolled_up],
      rollup_skipped: stats[:rollup_skipped],
      daily_prune_blocked: stats[:daily_prune_blocked]
    )
  end
end
