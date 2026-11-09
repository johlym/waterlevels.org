# One IvRepairBatchJob sweep at a time.
class IvRepairBatchLock
  extend SingletonRunLock

  KEY = "iv_repair_batch"
  DEFAULT_OWNER = "iv-repair-batch"
  STALE_AFTER = 15.minutes
end
