class ContinuousPruneJob < ApplicationJob
  queue_as :default

  def perform
    ContinuousObservation.where("observed_at < ?", HistoryIngestion::CONTINUOUS_RETENTION.ago).delete_all
    DailyObservation.where("observed_on < ?", HistoryIngestion::DAILY_RETENTION.ago.to_date).delete_all
  end
end
