# One FloodStageSyncJob at a time, including copies still waiting in the sync queue.
class FloodStageSyncLock
  extend SingletonRunLock

  KEY = "flood_stage_sync:running"
  DEFAULT_OWNER = "flood-stage-sync"
  STALE_AFTER = 2.hours
end
