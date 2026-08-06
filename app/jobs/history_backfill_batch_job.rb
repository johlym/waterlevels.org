class HistoryBackfillBatchJob < ApplicationJob
  queue_as :backfill

  # Page through candidates so locked/cooling low IDs cannot starve the rest.
  CANDIDATE_PAGE = 200
  # Per available history key. Sized so cold phase-1 work (~20 USGS pages/station)
  # approaches the 1000 req/hr key cap. Total phase-1 slots = this × available keys.
  DEFAULT_PHASE1_PER_KEY = 50
  # Per-key ceiling for deep work after phase-1; actual deep slots also shrink to
  # whatever request budget phase-1 did not consume.
  DEFAULT_DEEP_PER_KEY = 400

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

    keys = Usgs::HistoryKeyPool.available_count
    request_budget = Usgs::HistoryKeyPool.hourly_request_budget
    phase1_budget = phase1_station_budget(limit, keys)
    phase1_cost = phase1_requests_per_station

    phase1_enqueued = enqueue_candidates(
      MonitoringLocation.needing_history_backfill,
      range: range,
      budget: phase1_budget
    )

    deep_budget = deep_station_budget(
      keys: keys,
      request_budget: request_budget,
      phase1_enqueued: phase1_enqueued,
      phase1_cost: phase1_cost
    )
    deep_enqueued = enqueue_candidates(
      MonitoringLocation.needing_deep_history_backfill,
      range: HistoryIngestion::DEEP_RANGE,
      budget: deep_budget
    )

    total = phase1_enqueued + deep_enqueued
    estimated_requests = (phase1_enqueued * phase1_cost) +
      (deep_enqueued * deep_requests_per_station)
    Rails.logger.info(
      "HistoryBackfillBatchJob enqueued=#{total} phase1_enqueued=#{phase1_enqueued} " \
      "deep_enqueued=#{deep_enqueued} phase1_budget=#{phase1_budget} " \
      "deep_budget=#{deep_budget} history_keys=#{keys} " \
      "request_budget=#{request_budget} estimated_requests=#{estimated_requests} " \
      "range=#{range}"
    )
    total
  end

  private

  def phase1_station_budget(limit, keys)
    # Explicit perform(limit) stays an absolute station count (tests / one-offs).
    return limit.to_i if !limit.nil?

    per_key = ENV.fetch("HISTORY_BACKFILL_BATCH", DEFAULT_PHASE1_PER_KEY.to_s).to_i
    per_key = DEFAULT_PHASE1_PER_KEY if per_key <= 0
    per_key * keys
  end

  def deep_station_budget(keys:, request_budget:, phase1_enqueued:, phase1_cost:)
    per_key = ENV.fetch("HISTORY_DEEP_BACKFILL_BATCH", DEFAULT_DEEP_PER_KEY.to_s).to_i
    return 0 if per_key <= 0

    ceiling = per_key * keys
    remaining_requests = request_budget - (phase1_enqueued * phase1_cost)
    return 0 if remaining_requests <= 0

    by_requests = remaining_requests / deep_requests_per_station
    [ ceiling, by_requests ].min
  end

  def phase1_requests_per_station
    raw = ENV.fetch(
      "HISTORY_PHASE1_REQUESTS_PER_STATION",
      Usgs::HistoryKeyPool::PHASE1_REQUESTS_PER_STATION.to_s
    ).to_i
    raw.positive? ? raw : Usgs::HistoryKeyPool::PHASE1_REQUESTS_PER_STATION
  end

  def deep_requests_per_station
    raw = ENV.fetch(
      "HISTORY_DEEP_REQUESTS_PER_STATION",
      Usgs::HistoryKeyPool::DEEP_REQUESTS_PER_STATION.to_s
    ).to_i
    raw.positive? ? raw : Usgs::HistoryKeyPool::DEEP_REQUESTS_PER_STATION
  end

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
