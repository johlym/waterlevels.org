namespace :usace do
  desc "Sync curated USACE CWMS project tips (Raystown, Hartwell, Okeechobee, …)"
  task sync: :environment do
    progress = SyncProgress.new("usace:sync")
    count = UsaceProjectSync.new(progress: progress).perform
    progress.finish("synced=#{count}")
  end

  desc "Backfill USACE daily archive history. SITE=usacenabraystown YEARS=3"
  task backfill: :environment do
    site = ENV.fetch("SITE")
    years = ENV.fetch("YEARS", "3").to_i
    location = MonitoringLocation.find_by!(site_number: site)
    abort "SITE=#{site} is not a USACE location" unless location.data_provider == DataProviders::USACE

    progress = SyncProgress.new("usace:backfill")
    entry = Usace::ProjectCatalog.find_by_site_number(site) || abort("Unknown USACE SITE=#{site}")
    UsaceProjectSync.new(progress: progress).sync_entry!(entry)
    UsaceHistoryIngestion.new(progress: progress).perform(location, years: years)
    progress.finish("site=#{site} years=#{years}")
  end

  desc "Enqueue USACE tip sync + history backfill for active catalog entries"
  task enqueue_bootstrap: :environment do
    UsaceProjectSyncJob.perform_later
    Usace::ProjectCatalog.active_entries.each do |entry|
      UsaceHistoryBackfillJob.perform_later(entry.site_number, ENV.fetch("YEARS", "3").to_i)
    end
    puts "Enqueued UsaceProjectSyncJob + #{Usace::ProjectCatalog.active_entries.size} history jobs"
  end
end
