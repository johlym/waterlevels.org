namespace :cdec do
  desc "Sync curated CDEC reservoir tips (Oroville, Shasta, Folsom, …)"
  task sync: :environment do
    progress = SyncProgress.new("cdec:sync")
    count = CdecReservoirSync.new(progress: progress).perform
    progress.finish("synced=#{count}")
  end

  desc "Backfill CDEC daily archive history. SITE=cdecoro YEARS=3"
  task backfill: :environment do
    site = ENV.fetch("SITE")
    years = ENV.fetch("YEARS", "3").to_i
    location = MonitoringLocation.find_by!(site_number: site)
    abort "SITE=#{site} is not a CDEC location" unless location.data_provider == DataProviders::CDEC

    progress = SyncProgress.new("cdec:backfill")
    entry = Cdec::ReservoirCatalog.find_by_site_number(site) || abort("Unknown CDEC SITE=#{site}")
    CdecReservoirSync.new(progress: progress).sync_entry!(entry)
    CdecHistoryIngestion.new(progress: progress).perform(location, years: years)
    progress.finish("site=#{site} years=#{years}")
  end

  desc "Enqueue CDEC tip sync + history backfill for active catalog entries"
  task enqueue_bootstrap: :environment do
    CdecReservoirSyncJob.perform_later
    Cdec::ReservoirCatalog.active_entries.each do |entry|
      CdecHistoryBackfillJob.perform_later(entry.site_number, ENV.fetch("YEARS", "3").to_i)
    end
    puts "Enqueued CdecReservoirSyncJob + #{Cdec::ReservoirCatalog.active_entries.size} history jobs"
  end
end
