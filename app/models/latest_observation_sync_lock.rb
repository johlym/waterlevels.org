# Prevents overlapping LatestObservationSync runs (hourly job, bootstrap, rake)
# from occupying both sync_worker threads and doubling USGS tip traffic.
class LatestObservationSyncLock
  KEY = "latest_observation_sync:running"
  # Safety TTL if a worker dies mid-job. A national pass is usually well under
  # an hour; release! is the happy path.
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
