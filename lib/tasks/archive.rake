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
    progress.finish("series=#{result[:series]} points=#{result[:points]}")
    puts "Daily archive export finished series=#{result[:series]} points=#{result[:points]}"
  end

  desc "Enqueue DailyArchiveExportJob (optional ONLY_COLD=1)"
  task enqueue_export_daily: :environment do
    only_cold = %w[1 true yes on].include?(ENV["ONLY_COLD"].to_s.strip.downcase)
    DailyArchiveExportJob.perform_later(only_cold: only_cold)
    puts "Enqueued DailyArchiveExportJob only_cold=#{only_cold}"
  end
end
