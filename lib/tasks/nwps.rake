namespace :nwps do
  desc "Sync NWS NWPS flood stages and categories (requires STATE=wa, or omit to enqueue all states)"
  task sync_flood_stages: :environment do
    if ENV["STATE"].present?
      state = Usgs::StateCodes.normalize_postal(ENV["STATE"])
      progress = SyncProgress.new("nwps:sync_flood_stages[#{state}]")
      FloodStageSync.new(state: state, progress: progress).perform
    else
      puts "STATE not set — enqueuing per-state FloodStageSyncJob via FloodStageSyncBatchJob"
      FloodStageSyncBatchJob.perform_later
    end
  end

  desc "Enqueue per-state flood stage sync jobs (optional STATE=wa). Jobs self-pace to ≥31s each."
  task enqueue_sync: :environment do
    if ENV["STATE"].present?
      state = Usgs::StateCodes.normalize_postal(ENV["STATE"])
      FloodStageSyncJob.perform_later(state)
      puts "Enqueued FloodStageSyncJob state=#{state}"
    else
      count = FloodStageSyncBatchJob.perform_now
      puts "Enqueued #{count} FloodStageSyncJob(s) via FloodStageSyncBatchJob"
    end
  end
end
