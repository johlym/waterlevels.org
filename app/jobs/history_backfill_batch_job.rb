class HistoryBackfillBatchJob < ApplicationJob
  queue_as :backfill

  def perform(limit = nil, range = "7d")
    batch_size = (limit || ENV.fetch("HISTORY_BACKFILL_BATCH", "40")).to_i
    batch_size = 40 if batch_size <= 0

    ids = MonitoringLocation.needing_history_backfill.order(:id).limit(batch_size).pluck(:id)
    enqueued = ids.count { |id| HistoryBackfillJob.enqueue(id, range) }

    Rails.logger.info("HistoryBackfillBatchJob enqueued=#{enqueued} candidates=#{ids.size} range=#{range}")
    enqueued
  end
end
