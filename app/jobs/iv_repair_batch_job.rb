class IvRepairBatchJob < ApplicationJob
  queue_as :iv_repair

  CANDIDATE_PAGE = 200
  DEFAULT_BATCH = 100
  DEFAULT_QUEUE_BUSY_THRESHOLD = 25

  def perform(limit = nil)
    Telemetry.in_root_span(
      "job.iv_repair_batch",
      attributes: {
        "app.operation" => "job.iv_repair_batch"
      }
    ) do
      if IvRepairJob.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("IvRepairBatchJob skipped: Sunday catalog sync window")
        return 0
      end
      unless Usgs::HistoryKeyPool.iv_repair_available?
        Telemetry.add_attributes("app.skip_reason" => "iv_repair_key_unavailable")
        Rails.logger.info("IvRepairBatchJob skipped: USGS IV repair rate limit circuit open")
        return 0
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end
      if iv_repair_queue_busy?
        Telemetry.add_attributes("app.skip_reason" => "iv_repair_queue_busy")
        Rails.logger.info("IvRepairBatchJob skipped: iv_repair queue still draining")
        return 0
      end

      budget = station_budget(limit)
      Rails.logger.info("IvRepairBatchJob scanning candidates budget=#{budget}")

      enqueued = enqueue_candidates(budget)
      Telemetry.add_attributes(
        "app.batch_size" => enqueued,
        "app.iv_repair_budget" => budget,
        "app.iv_repair_available" => Usgs::HistoryKeyPool.iv_repair_available?
      )
      Rails.logger.info("IvRepairBatchJob enqueued=#{enqueued} budget=#{budget}")
      enqueued
    end
  end

  private

  def station_budget(limit)
    return limit.to_i if !limit.nil?
    return 0 unless Usgs::HistoryKeyPool.iv_repair_available?

    per_tick = ENV.fetch("HISTORY_IV_REPAIR_BATCH", DEFAULT_BATCH.to_s).to_i
    per_tick = DEFAULT_BATCH if per_tick <= 0
    [ per_tick, theoretical_ceiling ].min
  end

  def theoretical_ceiling
    cost = ENV.fetch(
      "HISTORY_IV_REPAIR_REQUESTS_PER_STATION",
      Usgs::HistoryKeyPool::IV_REPAIR_REQUESTS_PER_STATION.to_s
    ).to_i
    cost = Usgs::HistoryKeyPool::IV_REPAIR_REQUESTS_PER_STATION if cost <= 0
    Usgs::HistoryKeyPool::HOURLY_REQUEST_LIMIT / cost
  end

  def iv_repair_queue_busy?
    threshold = ENV.fetch(
      "HISTORY_IV_REPAIR_QUEUE_BUSY",
      DEFAULT_QUEUE_BUSY_THRESHOLD.to_s
    ).to_i
    return false if threshold <= 0

    require "sidekiq/api"
    Sidekiq::Queue.new("iv_repair").size >= threshold
  rescue StandardError
    false
  end

  def enqueue_candidates(budget)
    return 0 if budget <= 0

    scope = MonitoringLocation.needing_iv_repair
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

        if IvRepairJob.enqueue(id)
          enqueued += 1
        else
          skipped += 1
        end
      end
    end

    Rails.logger.info(
      "IvRepairBatchJob enqueued=#{enqueued} skipped=#{skipped} scanned=#{scanned} budget=#{budget}"
    )
    enqueued
  end
end
