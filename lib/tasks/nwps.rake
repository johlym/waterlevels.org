namespace :nwps do
  desc "Sync NWS NWPS flood stages and categories (optional STATE=wa)"
  task sync_flood_stages: :environment do
    state = ENV["STATE"]
    progress = SyncProgress.new("nwps:sync_flood_stages")
    FloodStageSync.new(state: state, progress: progress).perform
  end

  desc "Enqueue staggered per-state flood stage sync jobs (optional STATE=wa, DELAY_SECONDS=30)"
  task enqueue_sync: :environment do
    delay = ENV.fetch("DELAY_SECONDS", "30").to_i
    delay = 0 if delay.negative?

    states = if ENV["STATE"].present?
      [ Usgs::StateCodes.normalize_postal(ENV["STATE"]) ]
    else
      Usgs::StateCodes::STATES.keys.sort
    end

    states.each_with_index do |state, index|
      wait = index * delay
      if wait.positive?
        FloodStageSyncJob.set(wait: wait.seconds).perform_later(state)
      else
        FloodStageSyncJob.perform_later(state)
      end
    end

    puts "Enqueued #{states.size} FloodStageSyncJob(s) delay_seconds=#{delay}"
    puts "States: #{states.join(", ")}"
  end
end
