namespace :nwps do
  desc "Sync NWS NWPS flood stages and categories (optional STATE=wa)"
  task sync_flood_stages: :environment do
    state = ENV["STATE"]
    progress = SyncProgress.new("nwps:sync_flood_stages")
    FloodStageSync.new(state: state, progress: progress).perform
  end
end
