# One NetworkRefreshBatchJob at a time (weekly cron and catalog enqueue).
class NetworkRefreshBatchLock
  extend SingletonRunLock

  KEY = "network_refresh_batch:running"
  DEFAULT_OWNER = "network-refresh-batch"
  STALE_AFTER = 2.hours
end
