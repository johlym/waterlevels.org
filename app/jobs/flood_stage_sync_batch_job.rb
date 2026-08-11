class FloodStageSyncBatchJob < ApplicationJob
  queue_as :sync

  # Hourly cron entrypoint: enqueue one FloodStageSyncJob per state. Each state
  # job enforces a 31s minimum cycle and takes FloodStageSyncLock so only one
  # flood job runs at a time on the multi-thread sync worker.
  def perform
    Telemetry.in_root_span(
      "job.flood_sync_batch",
      attributes: { "app.operation" => "job.flood_sync_batch" }
    ) do
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      if prior_flood_sync_draining?
        Telemetry.add_attributes("app.skip_reason" => "flood_sync_draining")
        Rails.logger.info("FloodStageSyncBatchJob skipped: prior flood sync still draining")
        return 0
      end

      states = Usgs::StateCodes::STATES.keys.sort
      states.each do |state|
        FloodStageSyncJob.perform_later(state)
      end

      Rails.logger.info(
        "FloodStageSyncBatchJob enqueued=#{states.size} states=#{states.join(",")}"
      )
      Telemetry.add_attributes("app.batch_size" => states.size)
      states.size
    end
  end

  private

  def prior_flood_sync_draining?
    return false unless defined?(Sidekiq)

    require "sidekiq/api"
    Sidekiq::Queue.new("sync").any? { |job| flood_sync_job?(job) }
  rescue NameError, RedisClient::Error, Redis::BaseError, Errno::ECONNREFUSED
    false
  end

  def flood_sync_job?(job)
    payload = job.args.first
    return false unless payload.is_a?(Hash)

    payload["job_class"] == "FloodStageSyncJob" ||
      payload["job_class"] == "FloodStageSyncBatchJob"
  end
end
