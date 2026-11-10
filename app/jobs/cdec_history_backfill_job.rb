class CdecHistoryBackfillJob < ApplicationJob
  include ProviderHistoryBackfill

  queue_as :backfill

  def perform(site_number, years = HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS)
    Telemetry.work(
      "cdec_history",
      provider: "cdec",
      site_number: site_number.to_s,
      range: "#{years}y"
    ) do
      location = require_synced_location!(site_number)
      raise ArgumentError, "not a CDEC location" unless location.data_provider == DataProviders::CDEC

      progress = SyncProgress.new("CdecHistoryBackfillJob", io: nil, every: 1)
      CdecHistoryIngestion.new(progress: progress).perform(location, years: years.to_i)
      progress.finish("site=#{site_number} years=#{years}")
    end
  end
end
