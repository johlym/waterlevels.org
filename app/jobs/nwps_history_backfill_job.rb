class NwpsHistoryBackfillJob < ApplicationJob
  include ProviderHistoryBackfill

  queue_as :backfill

  def perform(site_number)
    Telemetry.in_root_span(
      "job.nwps_history_backfill",
      attributes: {
        "app.operation" => "job.nwps_history_backfill",
        "app.site_number" => site_number.to_s
      }
    ) do
      location = require_synced_location!(site_number)
      raise ArgumentError, "not an NWPS location" unless location.data_provider == DataProviders::NWPS

      progress = SyncProgress.new("NwpsHistoryBackfillJob", io: nil, every: 1)
      NwpsHistoryIngestion.new(progress: progress).perform(location)
      progress.finish("site=#{site_number}")
    end
  end
end
