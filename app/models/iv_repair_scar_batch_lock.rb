# One IvRepairScarBatchJob sweep at a time.
class IvRepairScarBatchLock
  extend SingletonRunLock

  KEY = "iv_repair_scar_batch"
  DEFAULT_OWNER = "iv-repair-scar-batch"
  STALE_AFTER = 15.minutes
end
