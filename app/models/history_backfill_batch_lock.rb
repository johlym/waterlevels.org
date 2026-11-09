# One HistoryBackfillBatchJob tick at a time.
class HistoryBackfillBatchLock
  extend SingletonRunLock

  KEY = "history_backfill_batch:running"
  DEFAULT_OWNER = "history-backfill-batch"
  STALE_AFTER = 30.minutes
end
