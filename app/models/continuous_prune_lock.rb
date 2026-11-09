# One ContinuousPruneJob at a time. The default worker runs two threads so
# edge purges and admin counters can proceed while a prune is in flight.
class ContinuousPruneLock
  extend SingletonRunLock

  KEY = "continuous_prune:running"
  DEFAULT_OWNER = "continuous-prune"
  STALE_AFTER = 36.hours
end
