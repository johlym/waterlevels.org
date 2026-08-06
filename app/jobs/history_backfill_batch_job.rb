class HistoryBackfillBatchJob < ApplicationJob
  queue_as :backfill

  # Page through candidates so locked/cooling low IDs cannot starve the rest.
  CANDIDATE_PAGE = 200

  def perform(limit = nil, range = HistoryIngestion::DEFAULT_RANGE)
    if HistoryBackfillJob.paused_for_catalog_sync?
      Rails.logger.info("HistoryBackfillBatchJob skipped: Sunday catalog sync window")
      return 0
    end
    if Usgs::HistoryKeyPool.exhausted?
      Rails.logger.info("HistoryBackfillBatchJob skipped: USGS history rate limit circuits open")
      return 0
    end
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end

    phase1_budget = (limit || ENV.fetch("HISTORY_BACKFILL_BATCH", "40")).to_i
    phase1_budget = 40 if phase1_budget <= 0
    deep_budget = ENV.fetch("HISTORY_DEEP_BACKFILL_BATCH", "10").to_i
    deep_budget = 0 if deep_budget.negative?

    phase1_enqueued = enqueue_candidates(
      MonitoringLocation.needing_history_backfill,
      range: range,
      budget: phase1_budget
    )
    deep_enqueued = enqueue_candidates(
      MonitoringLocation.needing_deep_history_backfill,
      range: HistoryIngestion::DEEP_RANGE,
      budget: deep_budget
    )

    total = phase1_enqueued + deep_enqueued
    Rails.logger.info(
      "HistoryBackfillBatchJob enqueued=#{total} phase1_enqueued=#{phase1_enqueued} " \
      "deep_enqueued=#{deep_enqueued} phase1_budget=#{phase1_budget} " \
      "deep_budget=#{deep_budget} range=#{range}"
    )
    total
  end

  private

  def enqueue_candidates(scope, range:, budget:)
    return 0 if budget <= 0

    enqueued = 0
    skipped = 0
    scanned = 0
    last_id = 0

    loop do
      break if enqueued >= budget

      ids = scope
        .where("monitoring_locations.id > ?", last_id)
        .order(:id)
        .limit(CANDIDATE_PAGE)
        .pluck(:id)
      break if ids.empty?

      ids.each do |id|
        last_id = id
        scanned += 1
        break if enqueued >= budget

        if HistoryBackfillJob.enqueue(id, range)
          enqueued += 1
        else
          skipped += 1
        end
      end
    end

    Rails.logger.info(
      "HistoryBackfillBatchJob phase range=#{range} enqueued=#{enqueued} " \
      "skipped=#{skipped} scanned=#{scanned} budget=#{budget}"
    )
    enqueued
  end
end
