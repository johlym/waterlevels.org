namespace :usgs do
  desc "Sync monitoring location catalog and time series metadata"
  task sync_catalog: :environment do
    StationCatalogSync.new.perform
  end

  desc "Sync latest observations"
  task sync_latest: :environment do
    LatestObservationSync.new.perform
  end

  desc "Run catalog then latest sync (Day-1 bootstrap)"
  task bootstrap: :environment do
    StationCatalogSync.new.perform
    LatestObservationSync.new.perform
  end
end
