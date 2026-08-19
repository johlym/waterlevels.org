namespace :archive do
  desc "Export Postgres daily_observations into Cloudflare R2 year shards (optional ONLY_COLD=1, LIMIT_SERIES=n)"
  task export_daily: :environment do
    unless DailyArchive.configured?
      raise "Daily archive store is not configured. For local/dev set DAILY_ARCHIVE_STORE=local; for R2 set CLOUDFLARE_R2_URL, CLOUDFLARE_R2_YEARLY_ARCHIVE_BUCKET, CLOUDFLARE_R2_ACCESS_KEY_ID, CLOUDFLARE_R2_SECRET_ACCESS_KEY"
    end

    only_cold = %w[1 true yes on].include?(ENV["ONLY_COLD"].to_s.strip.downcase)
    limit = ENV["LIMIT_SERIES"]&.to_i
    ids = nil
    if limit&.positive?
      ids = TimeSeries.order(:id).limit(limit).pluck(:id)
    end

    progress = SyncProgress.new("archive:export_daily")
    result = DailyArchive::Exporter.new(progress: progress).perform(
      time_series_ids: ids,
      only_cold: only_cold
    )
    progress.finish("series=#{result[:series]} points=#{result[:points]} daily_deleted=#{result[:daily_deleted]}")
    puts "Daily archive export finished series=#{result[:series]} points=#{result[:points]} daily_deleted=#{result[:daily_deleted]}"
  end

  desc "Enqueue DailyArchiveExportJob (optional ONLY_COLD=1)"
  task enqueue_export_daily: :environment do
    only_cold = %w[1 true yes on].include?(ENV["ONLY_COLD"].to_s.strip.downcase)
    DailyArchiveExportJob.perform_later(only_cold: only_cold)
    puts "Enqueued DailyArchiveExportJob only_cold=#{only_cold}"
  end

  desc "Delete leftover Postgres daily_observations already present in the archive, then VACUUM if needed"
  task drain_daily: :environment do
    unless DailyArchive.configured?
      raise "Daily archive store is not configured. For local/dev set DAILY_ARCHIVE_STORE=local; for R2 set CLOUDFLARE_R2_* credentials"
    end
    unless DailyArchive.prune_enabled?
      raise "Daily archive prune is disabled. Set DAILY_ARCHIVE_PRUNE=1 (or enable it on /admin) before draining leftover Postgres dailies"
    end

    progress = SyncProgress.new("archive:drain_daily")
    result = DailyArchive::Drain.new(progress: progress).perform
    vacuum = DailyArchive::TableMaintenance.vacuum_after_deletes!(
      daily_deleted: result[:deleted],
      progress: progress
    )
    progress.finish(
      "daily_deleted=#{result[:deleted]} daily_blocked=#{result[:blocked]} vacuumed=#{vacuum[:vacuumed]}"
    )
    puts "Daily archive drain finished deleted=#{result[:deleted]} blocked=#{result[:blocked]} vacuumed=#{vacuum[:vacuumed]}"
  end

  desc "Enqueue DailyArchiveDrainJob"
  task enqueue_drain_daily: :environment do
    DailyArchiveDrainJob.perform_later
    puts "Enqueued DailyArchiveDrainJob"
  end
end
