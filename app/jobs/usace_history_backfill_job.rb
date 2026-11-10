class UsaceHistoryBackfillJob < ApplicationJob
  include ProviderHistoryBackfill

  queue_as :backfill

  def perform(site_number, years = HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS)
    Telemetry.work(
      "usace_history",
      provider: "usace",
      site_number: site_number.to_s,
      range: "#{years}y"
    ) do
      location = require_synced_location!(site_number)
      raise ArgumentError, "not a USACE location" unless location.data_provider == DataProviders::USACE

      progress = SyncProgress.new("UsaceHistoryBackfillJob", io: nil, every: 1)
      UsaceHistoryIngestion.new(progress: progress).perform(location, years: years.to_i)
      progress.finish("site=#{site_number} years=#{years}")
    end
  end
end
