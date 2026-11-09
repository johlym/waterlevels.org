# One ContinuousPruneJob at a time. The default worker runs two threads so
# edge purges and admin counters can proceed while a prune is in flight; a
# second prune must not take the other thread.
class ContinuousPruneLock
  KEY = "continuous_prune:running"
  # A national pass can outlast the daily cron. release! is the happy path.
  # This only matters when the worker dies mid-run.
  TTL = 36.hours

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
