namespace :usgs do
  desc "Sync monitoring location catalog and time series metadata (optional STATE=wa)"
  task sync_catalog: :environment do
    state = ENV["STATE"]
    progress = SyncProgress.new("usgs:sync_catalog")
    StationCatalogSync.new(state: state, progress: progress).perform
  end

  desc "Sync latest observations (optional STATE=wa)"
  task sync_latest: :environment do
    state = ENV["STATE"]
    progress = SyncProgress.new("usgs:sync_latest")
    LatestObservationSync.new(state: state, progress: progress).perform
  end

  desc "Run catalog then latest sync (optional STATE=wa for a single-state bootstrap)"
  task bootstrap: :environment do
    state = ENV["STATE"]
    puts "USGS bootstrap starting#{" for STATE=#{state}" if state.present?}"

    catalog = SyncProgress.new("usgs:sync_catalog")
    StationCatalogSync.new(state: state, progress: catalog).perform

    latest = SyncProgress.new("usgs:sync_latest")
    LatestObservationSync.new(state: state, progress: latest).perform

    puts "USGS bootstrap finished"
  end

  desc "Backfill history for locations (STATE=wa RANGE=7d, optional LIMIT=n)"
  task backfill: :environment do
    state = ENV.fetch("STATE") { raise "STATE is required, e.g. STATE=wa bin/rails usgs:backfill" }
    range = ENV.fetch("RANGE", "7d")
    limit = ENV["LIMIT"]&.to_i

    scope = MonitoringLocation.in_state(Usgs::StateCodes.normalize_postal(state)).order(:site_number)
    scope = scope.limit(limit) if limit&.positive?
    total = scope.count
    puts "USGS history backfill starting state=#{state} range=#{range} locations=#{total}"

    scope.find_each.with_index(1) do |location, index|
      progress = SyncProgress.new("usgs:backfill #{index}/#{total}")
      HistoryIngestion.new(monitoring_location: location, range: range, progress: progress).perform
    end

    puts "USGS history backfill finished"
  end
end
