# Prevents overlapping HistoryBackfillBatchJob ticks from occupying both
# historical_worker threads (concurrency 2) during candidate scans.
class HistoryBackfillBatchLock
  KEY = "history_backfill_batch:running"
  TTL = 30.minutes

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
