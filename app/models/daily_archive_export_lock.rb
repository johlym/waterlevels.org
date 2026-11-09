# One DailyArchiveExportJob at a time.
class DailyArchiveExportLock
  extend SingletonRunLock

  KEY = "daily_archive_export:running"
  DEFAULT_OWNER = "daily-archive-export"
  STALE_AFTER = 8.hours
end
