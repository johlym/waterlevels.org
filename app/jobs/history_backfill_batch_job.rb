class HistoryBackfillBatchJob < ApplicationJob
  queue_as :backfill

  # Page through candidates so locked/cooling low IDs cannot starve the rest.
  CANDIDATE_PAGE = 200

  def perform(limit = nil, range = HistoryIngestion::DEFAULT_RANGE)
    if HistoryBackfillJob.paused_for_catalog_sync?
      Rails.logger.info("HistoryBackfillBatchJob skipped: Sunday catalog sync window")
      return 0
    end
    if Usgs::RateLimitCircuit.open?
      Rails.logger.info("HistoryBackfillBatchJob skipped: USGS rate limit circuit open")
      return 0
    end

    batch_size = (limit || ENV.fetch("HISTORY_BACKFILL_BATCH", "40")).to_i
    batch_size = 40 if batch_size <= 0

    enqueued = 0
    skipped = 0
    scanned = 0
    last_id = 0

    loop do
      break if enqueued >= batch_size

      ids = MonitoringLocation.needing_history_backfill
        .where("monitoring_locations.id > ?", last_id)
        .order(:id)
        .limit(CANDIDATE_PAGE)
        .pluck(:id)
      break if ids.empty?

      ids.each do |id|
        last_id = id
        scanned += 1
        break if enqueued >= batch_size

        if HistoryBackfillJob.enqueue(id, range)
          enqueued += 1
        else
          skipped += 1
        end
      end
    end

    Rails.logger.info(
      "HistoryBackfillBatchJob enqueued=#{enqueued} skipped=#{skipped} " \
      "scanned=#{scanned} batch_size=#{batch_size} range=#{range}"
    )
    enqueued
  end
end
