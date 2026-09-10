# Prevents overlapping StationCatalogSync runs (Sunday job, bootstrap, rake)
# from occupying both sync_worker threads and backing up tip/flood/network jobs.
class StationCatalogSyncLock
  KEY = "station_catalog_sync:running"
  # Safety TTL if a worker dies mid-job. A national Sunday pass can run for
  # hours (parameter paging + prune + cache warm); release! is the happy path.
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
