module Admin
  module Settings
    class PipelineJobs
      def self.register!
        Admin::SettingsRegistry.group :pipeline_jobs,
          title: "Pipeline jobs",
          description: "Pause or resume scheduled sync lanes without redeploying. Disabled jobs finish immediately as skipped." do
          boolean :latest_observation_sync_enabled,
            default: true,
            label: "Hourly tip sync",
            description: "When off, LatestObservationSyncJob no-ops at the start of each run."

          boolean :station_catalog_sync_enabled,
            default: true,
            label: "Weekly catalog sync",
            description: "When off, StationCatalogSyncJob skips its Sunday national catalog refresh."

          boolean :flood_stage_sync_enabled,
            default: true,
            label: "Flood stage sync",
            description: "When off, FloodStageSyncJob skips NWPS flood-stage pulls."

          boolean :history_backfill_enabled,
            default: true,
            label: "History backfill batch",
            description: "When off, HistoryBackfillBatchJob does not enqueue cold 1y fills."

          boolean :deep_backfill_enabled,
            default: true,
            label: "Deep 3y backfill",
            description: "When off, deep (3y) daily fills are paused (same idea as HISTORY_DEEP_BACKFILL_BATCH=0)."

          boolean :iv_repair_enabled,
            default: true,
            label: "IV repair batch",
            description: "When off, IvRepairBatchJob skips and tip-sync will not enqueue IvRepairJob."

          boolean :iv_scar_enabled,
            default: true,
            label: "IV scar batch",
            description: "When off, IvRepairScarBatchJob skips and does not enqueue scar repairs."

          boolean :continuous_prune_enabled,
            default: true,
            label: "Continuous prune / archive retention",
            description: "When off, ContinuousPruneJob skips daily archive retention and IV prune."

          boolean :daily_archive_drain_enabled,
            default: true,
            label: "Periodic leftover daily drain",
            description: "When off, DailyArchiveDrainJob skips the 6-hour leftover Postgres daily cleanup (already-in-R2 deletes + VACUUM)."

          boolean :sunday_catalog_pause_enabled,
            default: true,
            label: "Sunday catalog pause",
            description: "When on (default), history backfill and IV repair lanes pause on Sundays so the catalog sync can use the USGS budget."
        end
      end
    end
  end
end
