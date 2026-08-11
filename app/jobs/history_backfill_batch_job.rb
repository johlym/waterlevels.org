class HistoryBackfillBatchJob < ApplicationJob
  queue_as :backfill

  # Page through candidates so locked/cooling low IDs cannot starve the rest.
  CANDIDATE_PAGE = 200
  # Absolute station ceiling per cron tick for cold phase-1 work. Purpose-pinned
  # keys are not parallel capacity multipliers (continuous/daily/peaks run on the
  # same single backfill worker), so this is no longer × key count.
  DEFAULT_PHASE1_BATCH = 50
  # Absolute ceiling for deep 3y daily fills after phase-1. Set 0 to pause deep.
  DEFAULT_DEEP_BATCH = 400
  # Skip refill when the backfill queue already has this many jobs pending so
  # frequent cron ticks do not pile onto an already-busy worker.
  DEFAULT_QUEUE_BUSY_THRESHOLD = 5

  def perform(limit = nil, range = HistoryIngestion::DEFAULT_RANGE)
    Telemetry.in_root_span(
      "job.history_backfill_batch",
      attributes: {
        "app.operation" => "job.history_backfill_batch",
        "app.range" => range.to_s
      }
    ) do
      if HistoryBackfillJob.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("HistoryBackfillBatchJob skipped: Sunday catalog sync window")
        return 0
      end
      unless Usgs::HistoryKeyPool.phase1_available? || Usgs::HistoryKeyPool.deep_available?
        Telemetry.add_attributes("app.skip_reason" => "history_keys_exhausted")
        Rails.logger.info("HistoryBackfillBatchJob skipped: USGS history rate limit circuits open")
        return 0
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      if backfill_queue_busy?
        Telemetry.add_attributes("app.skip_reason" => "backfill_queue_busy")
        Rails.logger.info("HistoryBackfillBatchJob skipped: backfill queue still draining")
        return 0
      end

      phase1_budget = phase1_station_budget(limit)
      deep_budget = deep_station_budget
      Rails.logger.info(
        "HistoryBackfillBatchJob scanning candidates phase1_budget=#{phase1_budget} " \
        "deep_budget=#{deep_budget} range=#{range}"
      )

      phase1_enqueued = timed_phase("phase1_scope_and_enqueue") do
        enqueue_candidates(
          build_phase1_scope,
          range: range,
          budget: phase1_budget
        )
      end

      deep_enqueued = timed_phase("deep_scope_and_enqueue") do
        enqueue_candidates(
          build_deep_scope,
          range: HistoryIngestion::DEEP_RANGE,
          budget: deep_budget
        )
      end

      total = phase1_enqueued + deep_enqueued
      Telemetry.add_attributes(
        "app.batch_size" => total,
        "app.phase1_enqueued" => phase1_enqueued,
        "app.deep_enqueued" => deep_enqueued,
        "app.phase1_budget" => phase1_budget,
        "app.deep_budget" => deep_budget,
        "app.continuous_available" => Usgs::HistoryKeyPool.available?(:continuous),
        "app.daily_available" => Usgs::HistoryKeyPool.available?(:daily),
        "app.peaks_available" => Usgs::HistoryKeyPool.available?(:peaks)
      )
      Rails.logger.info(
        "HistoryBackfillBatchJob enqueued=#{total} phase1_enqueued=#{phase1_enqueued} " \
        "deep_enqueued=#{deep_enqueued} phase1_budget=#{phase1_budget} " \
        "deep_budget=#{deep_budget} continuous=#{Usgs::HistoryKeyPool.available?(:continuous)} " \
        "daily=#{Usgs::HistoryKeyPool.available?(:daily)} " \
        "peaks=#{Usgs::HistoryKeyPool.available?(:peaks)} range=#{range}"
      )
      total
    end
  end

  private

  def phase1_station_budget(limit)
    # Explicit perform(limit) stays an absolute station count (tests / one-offs).
    return limit.to_i if !limit.nil?
    return 0 unless Usgs::HistoryKeyPool.phase1_available?

    per_tick = ENV.fetch("HISTORY_BACKFILL_BATCH", DEFAULT_PHASE1_BATCH.to_s).to_i
    per_tick = DEFAULT_PHASE1_BATCH if per_tick <= 0
    [ per_tick, theoretical_phase1_ceiling ].min
  end

  def deep_station_budget
    return 0 unless Usgs::HistoryKeyPool.deep_available?

    per_tick = ENV.fetch("HISTORY_DEEP_BACKFILL_BATCH", DEFAULT_DEEP_BATCH.to_s).to_i
    return 0 if per_tick <= 0

    [ per_tick, theoretical_deep_ceiling ].min
  end

  # Soft planning ceiling from USGS's documented 1000/hr — not a live remaining
  # counter (we cannot accurately mirror USGS quota locally).
  def theoretical_phase1_ceiling
    cost = phase1_requests_per_station
    Usgs::HistoryKeyPool::HOURLY_REQUEST_LIMIT / [ cost, 1 ].max
  end

  def theoretical_deep_ceiling
    cost = deep_requests_per_station
    Usgs::HistoryKeyPool::HOURLY_REQUEST_LIMIT / [ cost, 1 ].max
  end

  def backfill_queue_busy?
    threshold = ENV.fetch(
      "HISTORY_BACKFILL_QUEUE_BUSY",
      DEFAULT_QUEUE_BUSY_THRESHOLD.to_s
    ).to_i
    return false if threshold <= 0

    require "sidekiq/api"
    Sidekiq::Queue.new("backfill").size >= threshold
  rescue StandardError
    false
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

  def build_phase1_scope
    Rails.logger.info("HistoryBackfillBatchJob building needing_history_backfill scope")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scope = MonitoringLocation.needing_history_backfill
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("HistoryBackfillBatchJob needing_history_backfill scope ready elapsed_ms=#{elapsed_ms}")
    scope
  end

  def build_deep_scope
    Rails.logger.info("HistoryBackfillBatchJob building needing_deep_history_backfill scope")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    scope = MonitoringLocation.needing_deep_history_backfill
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("HistoryBackfillBatchJob needing_deep_history_backfill scope ready elapsed_ms=#{elapsed_ms}")
    scope
  end

  def timed_phase(label)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("HistoryBackfillBatchJob #{label} elapsed_ms=#{elapsed_ms} result=#{result}")
    result
  end

  def enqueue_candidates(scope, range:, budget:)
    return 0 if budget <= 0

    enqueued = 0
    skipped = 0
    scanned = 0
    last_id = 0
    page = 0

    loop do
      break if enqueued >= budget

      page += 1
      Rails.logger.info(
        "HistoryBackfillBatchJob phase range=#{range} fetching page=#{page} " \
        "last_id=#{last_id} enqueued=#{enqueued}/#{budget}"
      )
      page_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ids = scope
        .where("monitoring_locations.id > ?", last_id)
        .order(:id)
        .limit(CANDIDATE_PAGE)
        .pluck(:id)
      page_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - page_started) * 1000).round
      Rails.logger.info(
        "HistoryBackfillBatchJob phase range=#{range} page=#{page} " \
        "rows=#{ids.size} elapsed_ms=#{page_ms}"
      )
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
