# Prevents overlapping DailyArchiveExportJob runs from occupying both
# historical_worker threads for a long national export.
class DailyArchiveExportLock
  KEY = "daily_archive_export:running"
  # Safety TTL if a worker dies mid-export. release! is the happy path.
  TTL = 8.hours

  def self.claim!(ttl: TTL)
    Rails.cache.write(KEY, true, expires_in: ttl, unless_exist: true)
  end

  def self.release!
    Rails.cache.delete(KEY)
  end

  def self.locked?
    Rails.cache.exist?(KEY)
  end
end
