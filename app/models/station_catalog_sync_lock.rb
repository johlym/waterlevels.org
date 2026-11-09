# One StationCatalogSync at a time (Sunday job, bootstrap, rake).
class StationCatalogSyncLock
  extend SingletonRunLock

  KEY = "station_catalog_sync:running"
  DEFAULT_OWNER = "station-catalog-sync"
  STALE_AFTER = 8.hours
end
