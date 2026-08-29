class NetworkRefreshBatchJob < ApplicationJob
  queue_as :sync

  def perform(limit = nil)
    Telemetry.in_root_span(
      "job.network_refresh_batch",
      attributes: { "app.operation" => "job.network_refresh_batch" }
    ) do
      unless AppConfig.boolean?(:nldi_refresh_enabled)
        Telemetry.add_attributes("app.skip_reason" => "disabled_by_settings")
        Rails.logger.info("NetworkRefreshBatchJob skipped: disabled by admin settings")
        return 0
      end
      if HistoryBackfillJob.paused_for_catalog_sync?
        Telemetry.add_attributes("app.skip_reason" => "sunday_catalog_sync")
        Rails.logger.info("NetworkRefreshBatchJob skipped: Sunday catalog sync window")
        return 0
      end
      if DatabaseReadOnlyCircuit.open?
        Telemetry.add_attributes("app.skip_reason" => "db_read_only_circuit")
        raise DatabaseReadOnlyError, "database read-only circuit open"
      end

      budget = station_budget(limit)
      if budget <= 0
        Telemetry.add_attributes("app.skip_reason" => "batch_disabled", "app.batch_size" => 0)
        return 0
      end

      refreshed = NetworkStations.refresh(MonitoringLocation.order(:id), limit: budget)
      Telemetry.add_attributes("app.batch_size" => refreshed, "app.limit" => budget)
      Rails.logger.info("NetworkRefreshBatchJob refreshed=#{refreshed} budget=#{budget}")
      refreshed
    end
  end

  private

  def station_budget(limit)
    return limit.to_i unless limit.nil?

    AppConfig.integer(:nldi_refresh_batch)
  end
end
