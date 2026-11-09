# One LatestObservationSync at a time (hourly job, bootstrap, rake).
class LatestObservationSyncLock
  extend SingletonRunLock

  KEY = "latest_observation_sync:running"
  DEFAULT_OWNER = "latest-observation-sync"
  STALE_AFTER = 2.hours
end
