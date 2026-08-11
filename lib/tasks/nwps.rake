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
end
