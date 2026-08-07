class DailyArchiveExportJob < ApplicationJob
  queue_as :backfill

  def perform(time_series_ids: nil, only_cold: false)
    if DatabaseReadOnlyCircuit.open?
      raise DatabaseReadOnlyError, "database read-only circuit open"
    end
    return unless DailyArchive.configured?

    result = DailyArchive::Exporter.new.perform(
      time_series_ids: time_series_ids,
      only_cold: only_cold
    )
    AdminDashboardStats.record_job_finish!(
      :daily_archive_export,
      series: result[:series],
      points: result[:points]
    )
  end
end
