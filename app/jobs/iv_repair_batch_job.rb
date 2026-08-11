class IvRepairBatchJob < ApplicationJob
  queue_as :iv_repair

  # Catch-up sweeper only — tip sync enqueues IvRepairJob on tip jumps.
  # Keep this small so the reserved IV repair key stays available for
  # immediate gap fills after hourly tip sync.
  DEFAULT_BATCH = 50
  DEFAULT_QUEUE_BUSY_THRESHOLD = 25

  def perform(limit = nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Telemetry.in_root_span(
      "job.iv_repair_batch",
      attributes: {
        "app.operation" => "job.iv_repair_batch"
      }
    ) do
      queue_depth = iv_repair_queue_depth
      worker_count = iv_repair_worker_count
      Rails.logger.info(
        "IvRepairBatchJob start queue_depth=#{queue_depth} " \
        "iv_repair_workers=#{worker_count} " \
        "circuit_open=#{!Usgs::HistoryKeyPool.iv_repair_available?} " \
        "key_configured=#{Usgs::HistoryKeyPool.configured?(:iv_repair)} " \
        "circuit=#{Usgs::HistoryKeyPool.circuit_key_for(:iv_repair)}"
      )

      unless IvRepairBatchLock.claim!
        return finish_skipped!(
          "batch_lock_held",
          started,
          queue_depth: queue_depth,
          workers: worker_count
        )
      end

      begin
        perform_locked(limit, started, queue_depth: queue_depth, worker_count: worker_count)
      ensure
        IvRepairBatchLock.release!
      end
    end
  end

  private

  def perform_locked(limit, started, queue_depth:, worker_count:)
    if worker_count.zero? && queue_depth.positive?
      Rails.logger.warn(
        "IvRepairBatchJob: iv_repair queue has #{queue_depth} job(s) but no Sidekiq " \
        "process is listening — scale iv_repair_worker or jobs will sit"
      )
    elsif worker_count.zero?
      Rails.logger.warn(
        "IvRepairBatchJob: no Sidekiq process listening on iv_repair — " \
        "enqueued jobs will sit until iv_repair_worker is up"
      )
    end

    unless AppConfig.boolean?(:iv_repair_enabled)
      return finish_skipped!("disabled_by_settings", started, queue_depth: queue_depth, workers: worker_count)
    end
    if IvRepairJob.paused_for_catalog_sync?
      return finish_skipped!("sunday_catalog_sync", started, queue_depth: queue_depth, workers: worker_count)
    end
    unless Usgs::HistoryKeyPool.iv_repair_available?
      return finish_skipped!(
        "iv_repair_key_unavailable",
        started,
        queue_depth: queue_depth,
        workers: worker_count
      )
    end
    if DatabaseReadOnlyCircuit.open?
      Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    if iv_repair_queue_busy?(queue_depth)
      return finish_skipped!(
        "iv_repair_queue_busy",
        started,
        queue_depth: queue_depth,
        workers: worker_count,
        busy_threshold: queue_busy_threshold
      )
    end

    budget = station_budget(limit)
    Rails.logger.info("IvRepairBatchJob scanning candidates budget=#{budget}")

    scope_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    candidate_ids = MonitoringLocation.iv_repair_candidate_ids
    scope_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - scope_started) * 1000).round
    candidate_count = candidate_ids.size
    Rails.logger.info(
      "IvRepairBatchJob candidates ready count=#{candidate_count} " \
      "scope_elapsed_ms=#{scope_ms} budget=#{budget} — beginning enqueue"
    )

    result = enqueue_candidate_ids(candidate_ids, budget)
    elapsed_s = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
    depth_after = iv_repair_queue_depth

    Telemetry.add_attributes(
      "app.batch_size" => result[:enqueued],
      "app.iv_repair_budget" => budget,
      "app.iv_repair_candidates" => candidate_count,
      "app.iv_repair_available" => Usgs::HistoryKeyPool.iv_repair_available?,
      "app.queue_depth" => depth_after,
      "app.iv_repair_workers" => worker_count,
      "app.elapsed_s" => elapsed_s
    )
    Rails.logger.info(
      "IvRepairBatchJob finished enqueued=#{result[:enqueued]} " \
      "skipped=#{result[:skipped]} scanned=#{result[:scanned]} " \
      "candidates=#{candidate_count} budget=#{budget} " \
      "skip_reasons=#{result[:skip_reasons].inspect} " \
      "queue_depth_before=#{queue_depth} queue_depth_after=#{depth_after} " \
      "iv_repair_workers=#{worker_count} elapsed_s=#{elapsed_s}"
    )

    AdminDashboardStats.record_job_finish!(
      :iv_repair_batch,
      enqueued: result[:enqueued],
      skipped: result[:skipped],
      scanned: result[:scanned],
      candidates: candidate_count,
      budget: budget,
      skip_reasons: result[:skip_reasons],
      queue_depth_before: queue_depth,
      queue_depth_after: depth_after,
      workers: worker_count,
      elapsed_s: elapsed_s
    )

    if result[:enqueued].positive? && worker_count.zero?
      Rails.logger.warn(
        "IvRepairBatchJob enqueued #{result[:enqueued]} job(s) with zero iv_repair workers — " \
        "they will sit until iv_repair_worker is scaled on"
      )
    end

    result[:enqueued]
  end

  def finish_skipped!(reason, started, **extra)
    elapsed_s = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
    Telemetry.add_attributes("app.skip_reason" => reason, "app.elapsed_s" => elapsed_s)
    Rails.logger.info(
      "IvRepairBatchJob skipped reason=#{reason} elapsed_s=#{elapsed_s} #{extra.map { |k, v| "#{k}=#{v}" }.join(" ")}"
    )
    AdminDashboardStats.record_job_finish!(
      :iv_repair_batch,
      skipped_run: true,
      skip_reason: reason,
      elapsed_s: elapsed_s,
      **extra
    )
    0
  end

  def station_budget(limit)
    return limit.to_i if !limit.nil?
    return 0 unless Usgs::HistoryKeyPool.iv_repair_available?

    per_tick = AppConfig.integer(:history_iv_repair_batch)
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

  def queue_busy_threshold
    AppConfig.integer(:history_iv_repair_queue_busy)
  end

  def iv_repair_queue_busy?(depth = nil)
    threshold = queue_busy_threshold
    return false if threshold <= 0

    (depth || iv_repair_queue_depth) >= threshold
  end

  def iv_repair_queue_depth
    require "sidekiq/api"
    Sidekiq::Queue.new("iv_repair").size
  rescue StandardError => e
    Rails.logger.warn("IvRepairBatchJob queue_depth unavailable: #{e.class}: #{e.message}")
    0
  end

  def iv_repair_worker_count
    require "sidekiq/api"
    Sidekiq::ProcessSet.new.count { |process| Array(process["queues"]).include?("iv_repair") }
  rescue StandardError => e
    Rails.logger.warn("IvRepairBatchJob worker_count unavailable: #{e.class}: #{e.message}")
    -1
  end

  def enqueue_candidate_ids(candidate_ids, budget)
    empty = { enqueued: 0, skipped: 0, scanned: 0, skip_reasons: {} }
    return empty if budget <= 0 || candidate_ids.empty?

    enqueued = 0
    skipped = 0
    scanned = 0
    skip_reasons = Hash.new(0)

    candidate_ids.each do |id|
      break if enqueued >= budget

      scanned += 1
      reason = IvRepairJob.enqueue_block_reason(id)
      if reason
        skipped += 1
        skip_reasons[reason] += 1
        next
      end

      IvRepairJob.perform_later(id)
      enqueued += 1
      if (enqueued % 10).zero? || enqueued == budget
        Rails.logger.info(
          "IvRepairBatchJob enqueue progress enqueued=#{enqueued}/#{budget} " \
          "scanned=#{scanned}/#{candidate_ids.size} skipped=#{skipped}"
        )
      end
    end

    {
      enqueued: enqueued,
      skipped: skipped,
      scanned: scanned,
      skip_reasons: skip_reasons
    }
  end
end
