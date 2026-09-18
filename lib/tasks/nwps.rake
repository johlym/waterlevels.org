namespace :nwps do
  desc "Sync NWS NWPS flood stages and categories (optional STATE=wa; omit for all states)"
  task sync_flood_stages: :environment do
    state = ENV["STATE"].presence
    if state
      postal = Usgs::StateCodes.normalize_postal(state)
      progress = SyncProgress.new("nwps:sync_flood_stages[#{postal}]")
      FloodStageSync.new(state: postal, progress: progress).perform
    else
      progress = SyncProgress.new("nwps:sync_flood_stages")
      # Inline national loop (same pacing as the Sidekiq job) for console use.
      FloodStageSyncJob.perform_now
    end
  end

  desc "Enqueue flood stage sync (optional STATE=wa; omit for national paced loop)"
  task enqueue_sync: :environment do
    if ENV["STATE"].present?
      state = Usgs::StateCodes.normalize_postal(ENV["STATE"])
      FloodStageSyncJob.perform_later(state)
      puts "Enqueued FloodStageSyncJob state=#{state}"
    else
      FloodStageSyncJob.perform_later
      puts "Enqueued FloodStageSyncJob (national paced loop)"
    end
  end

  desc "Sync curated NWPS gauges that have no usgsId (primary MonitoringLocation rows)"
  task sync_gauges: :environment do
    progress = SyncProgress.new("nwps:sync_gauges")
    count = NwpsGaugeSync.new(progress: progress).perform
    progress.finish("synced=#{count}")
  end

  desc "Backfill NWPS stageflow continuous history. SITE=nwpsacrw1"
  task backfill_gauge: :environment do
    site = ENV.fetch("SITE")
    location = MonitoringLocation.find_by!(site_number: site)
    abort "SITE=#{site} is not an NWPS location" unless location.data_provider == DataProviders::NWPS

    progress = SyncProgress.new("nwps:backfill_gauge")
    entry = Nwps::GaugeCatalog.find_by_site_number(site) || abort("Unknown NWPS SITE=#{site}")
    NwpsGaugeSync.new(progress: progress).sync_entry!(entry)
    NwpsHistoryIngestion.new(progress: progress).perform(location)
    progress.finish("site=#{site}")
  end

  desc "Enqueue curated NWPS gauge tip sync + stageflow backfill"
  task enqueue_gauge_bootstrap: :environment do
    NwpsGaugeSyncJob.perform_later
    Nwps::GaugeCatalog.active_entries.each do |entry|
      NwpsHistoryBackfillJob.perform_later(entry.site_number)
    end
    puts "Enqueued NwpsGaugeSyncJob + #{Nwps::GaugeCatalog.active_entries.size} history jobs"
  end
end
