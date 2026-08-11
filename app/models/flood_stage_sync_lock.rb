# Prevents overlapping FloodStageSyncJob national (or single-state) runs on the
# multi-thread sync worker. Held for the whole job, including inter-state pacing.
class FloodStageSyncLock
  KEY = "flood_stage_sync:running"
  # Safety TTL if a worker dies mid-job. A full 53-state pass is ~30–60 minutes.
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
