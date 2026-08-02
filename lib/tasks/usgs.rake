namespace :usgs do
  desc "Sync monitoring location catalog and time series metadata (optional STATE=wa)"
  task sync_catalog: :environment do
    StationCatalogSync.new(state: ENV["STATE"]).perform
  end

  desc "Sync latest observations (optional STATE=wa)"
  task sync_latest: :environment do
    LatestObservationSync.new(state: ENV["STATE"]).perform
  end

  desc "Run catalog then latest sync (optional STATE=wa for a single-state bootstrap)"
  task bootstrap: :environment do
    state = ENV["STATE"]
    StationCatalogSync.new(state: state).perform
    LatestObservationSync.new(state: state).perform
  end
end
