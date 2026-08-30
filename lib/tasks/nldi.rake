namespace :nldi do
  desc "Refresh on-stream upstream/downstream neighbors (optional STATE=wa FORCE=1)"
  task refresh: :environment do
    scope = MonitoringLocation.order(:id)
    if ENV["STATE"].present?
      scope = scope.in_state(Usgs::StateCodes.normalize_postal(ENV["STATE"]))
    end
    force = ENV["FORCE"] == "1"
    limit = ENV["LIMIT"].presence&.to_i
    total = scope.count
    progress = SyncProgress.new("nldi:refresh")
    progress.step(
      "locations=#{total}#{" state=#{ENV['STATE']}" if ENV['STATE'].present?} " \
      "force=#{force}#{" limit=#{limit}" if limit}"
    )

    refreshed = NetworkStations.refresh(scope, force: force, limit: limit, progress: progress)
    progress.finish("refreshed=#{refreshed} locations=#{total}")
  end
end
