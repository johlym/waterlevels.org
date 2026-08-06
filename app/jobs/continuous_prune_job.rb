class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    continuous_deleted = ContinuousObservation.where(
      "observed_at < ?", HistoryIngestion::CONTINUOUS_RETENTION.ago
    ).delete_all
    daily_deleted = DailyObservation.where(
      "observed_on < ?", HistoryIngestion::DAILY_RETENTION.ago.to_date
    ).delete_all
    AdminDashboardStats.record_job_finish!(
      :prune,
      continuous_deleted: continuous_deleted,
      daily_deleted: daily_deleted
    )
  end
end
