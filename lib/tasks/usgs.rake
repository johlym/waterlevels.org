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

  desc "Enqueue staggered per-state bootstrap jobs (optional STATE=wa, DELAY_SECONDS=120)"
  task enqueue_bootstrap: :environment do
    delay = ENV.fetch("DELAY_SECONDS", "120").to_i
    delay = 0 if delay.negative?

    states = if ENV["STATE"].present?
      [ Usgs::StateCodes.normalize_postal(ENV["STATE"]) ]
    else
      Usgs::StateCodes::STATES.keys.sort
    end

    states.each_with_index do |state, index|
      wait = index * delay
      if wait.positive?
        BootstrapStateJob.set(wait: wait.seconds).perform_later(state)
      else
        BootstrapStateJob.perform_later(state)
      end
    end

    puts "Enqueued #{states.size} BootstrapStateJob(s) delay_seconds=#{delay}"
    puts "States: #{states.join(", ")}"
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

  desc "Re-apply display series selection and warm snapshots (optional STATE=wa)"
  task reselect: :environment do
    state = ENV["STATE"]
    scope = MonitoringLocation.includes(time_series: :latest_observation)
    scope = scope.in_state(Usgs::StateCodes.normalize_postal(state)) if state.present?
    total = scope.count
    progress = SyncProgress.new("usgs:reselect")
    progress.step("locations=#{total}#{" state=#{state}" if state.present?}")

    scope.find_each do |location|
      DisplaySeriesSelection.apply!(location)
      StationSnapshotCache.warm(location)
      progress.increment
    end

    progress.finish("locations=#{total}")
  end

  desc "Delete inactive/stale catalog rows (STATE=wa required; use ALL=1 to wipe the state)"
  task purge: :environment do
    state = ENV.fetch("STATE") { raise "STATE is required, e.g. STATE=wa bin/rails usgs:purge" }
    scope = MonitoringLocation.in_state(Usgs::StateCodes.normalize_postal(state))
    ids = if ENV["ALL"] == "1"
      scope.pluck(:id)
    else
      scope.where(latest_observed_at: nil)
        .or(scope.where("latest_observed_at < ?", MonitoringLocation::STALE_AFTER.ago))
        .pluck(:id)
    end

    deleted = MonitoringLocation.purge_ids!(ids)
    puts "Purged #{deleted} locations for STATE=#{state}"
  end
end
