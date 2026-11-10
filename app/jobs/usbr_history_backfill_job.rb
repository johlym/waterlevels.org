class UsbrHistoryBackfillJob < ApplicationJob
  include ProviderHistoryBackfill

  queue_as :backfill

  def perform(site_number, years = HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS)
    Telemetry.work(
      "usbr_history",
      provider: "usbr",
      site_number: site_number.to_s,
      range: "#{years}y"
    ) do
      location = require_synced_location!(site_number)
      raise ArgumentError, "not a USBR location" unless location.data_provider == DataProviders::USBR

      progress = SyncProgress.new("UsbrHistoryBackfillJob", io: nil, every: 1)
      UsbrHistoryIngestion.new(progress: progress).perform(location, years: years.to_i)
      progress.finish("site=#{site_number} years=#{years}")
    end
  end
end
