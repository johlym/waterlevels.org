class UsbrHistoryBackfillJob < ApplicationJob
  include ProviderHistoryBackfill

  queue_as :backfill

  def perform(site_number, years = 3)
    Telemetry.in_root_span(
      "job.usbr_history_backfill",
      attributes: {
        "app.operation" => "job.usbr_history_backfill",
        "app.site_number" => site_number.to_s,
        "app.range" => "#{years}y"
      }
    ) do
      location = require_synced_location!(site_number)
      raise ArgumentError, "not a USBR location" unless location.data_provider == DataProviders::USBR

      progress = SyncProgress.new("UsbrHistoryBackfillJob", io: nil, every: 1)
      UsbrHistoryIngestion.new(progress: progress).perform(location, years: years.to_i)
      progress.finish("site=#{site_number} years=#{years}")
    end
  end
end
