# Prevents overlapping NetworkRefreshBatchJob ticks (hourly cron + catalog
# enqueue) from taking both sync_worker threads while NLDI paces ~10s/station.
class NetworkRefreshBatchLock
  KEY = "network_refresh_batch:running"
  # Safety TTL if a worker dies mid-tick. A 50-station pass can run ~35–45
  # minutes; release! is the happy path.
  TTL = 2.hours

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
