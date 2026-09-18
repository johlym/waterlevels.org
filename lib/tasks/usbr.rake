namespace :usbr do
  desc "Sync curated USBR RISE reservoir tips (Lake Mead, …)"
  task sync: :environment do
    progress = SyncProgress.new("usbr:sync")
    count = UsbrReservoirSync.new(progress: progress).perform
    progress.finish("synced=#{count}")
  end

  desc "Backfill USBR daily archive history. SITE=usbr3514 YEARS=10"
  task backfill: :environment do
    site = ENV.fetch("SITE")
    years = ENV.fetch("YEARS", HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS.to_s).to_i
    location = MonitoringLocation.find_by!(site_number: site)
    abort "SITE=#{site} is not a USBR location" unless location.data_provider == DataProviders::USBR

    progress = SyncProgress.new("usbr:backfill")
    UsbrReservoirSync.new(progress: progress).sync_entry!(
      Usbr::ReservoirCatalog.find_by_site_number(site) || abort("Unknown USBR SITE=#{site}")
    )
    UsbrHistoryIngestion.new(progress: progress).perform(location, years: years)
    progress.finish("site=#{site} years=#{years}")
  end

  desc "Enqueue USBR tip sync + history backfill for active catalog entries"
  task enqueue_bootstrap: :environment do
    UsbrReservoirSyncJob.perform_later
    Usbr::ReservoirCatalog.active_entries.each do |entry|
      UsbrHistoryBackfillJob.perform_later(
        entry.site_number,
        ENV.fetch("YEARS", HistoryIngestion::DEFAULT_NON_USGS_DAILY_YEARS.to_s).to_i
      )
    end
    puts "Enqueued UsbrReservoirSyncJob + #{Usbr::ReservoirCatalog.active_entries.size} history jobs"
  end
end
