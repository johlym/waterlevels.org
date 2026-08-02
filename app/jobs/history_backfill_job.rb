class HistoryBackfillJob < ApplicationJob
  queue_as :backfill

  def perform(monitoring_location_id, range = "7d")
    location = MonitoringLocation.find(monitoring_location_id)
    HistoryIngestion.new(monitoring_location: location, range: range).perform
  end
end
