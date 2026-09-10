# Prevents overlapping NetworkRefreshBatchJob ticks (cron + catalog enqueue)
# from taking both sync_worker threads while NLDI paces ~10s/station.
class NetworkRefreshBatchLock
  KEY = "network_refresh_batch:running"
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
