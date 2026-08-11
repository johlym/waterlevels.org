# Serializes FloodStageSyncJob across the sync worker's threads so NWPS pacing
# stays one-request-at-a-time even when sidekiq_sync.yml concurrency is > 1.
class FloodStageSyncLock
  KEY = "flood_stage_sync:running"
  # Safety TTL if a worker dies mid-job. Healthy state jobs finish well under this.
  TTL = 15.minutes

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
