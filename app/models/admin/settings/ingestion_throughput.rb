module Admin
  module Settings
    class IngestionThroughput
      def self.register!
        Admin::SettingsRegistry.group :ingestion_throughput,
          title: "Ingestion throughput",
          description: "Batch sizes, queue-busy gates, and request pacing. Overrides win over matching ENV vars." do
          integer :history_backfill_batch,
            default: 50,
            env: "HISTORY_BACKFILL_BATCH",
            min: 1,
            max: 5_000,
            label: "History backfill batch",
            description: "Stations to enqueue per HistoryBackfillBatchJob tick for cold phase-1 (1y) work."

          integer :history_deep_backfill_batch,
            default: 400,
            env: "HISTORY_DEEP_BACKFILL_BATCH",
            min: 0,
            max: 5_000,
            label: "Deep backfill batch",
            description: "Stations to enqueue per tick for deep 3y fills. Set 0 to pause deep fills (also gated by the Deep 3y backfill lever)."

          integer :history_backfill_queue_busy,
            default: 5,
            env: "HISTORY_BACKFILL_QUEUE_BUSY",
            min: 0,
            max: 10_000,
            label: "Backfill queue busy threshold",
            description: "Skip a backfill batch tick when the backfill queue already has this many jobs. 0 disables the busy check."

          integer :history_iv_repair_batch,
            default: 50,
            env: "HISTORY_IV_REPAIR_BATCH",
            min: 1,
            max: 5_000,
            label: "IV repair batch",
            description: "Stations to enqueue per IvRepairBatchJob tick."

          integer :history_iv_repair_queue_busy,
            default: 25,
            env: "HISTORY_IV_REPAIR_QUEUE_BUSY",
            min: 0,
            max: 10_000,
            label: "IV repair queue busy threshold",
            description: "Skip IV repair batch ticks when the iv_repair queue depth is at least this high. 0 disables the check."

          integer :history_iv_scar_batch,
            default: 50,
            env: "HISTORY_IV_SCAR_BATCH",
            min: 1,
            max: 5_000,
            label: "IV scar batch",
            description: "Stations to enqueue per IvRepairScarBatchJob tick."

          integer :history_iv_scar_queue_busy,
            default: 25,
            env: "HISTORY_IV_SCAR_QUEUE_BUSY",
            min: 0,
            max: 10_000,
            label: "IV scar queue busy threshold",
            description: "Skip scar batch ticks when the iv_repair_scar queue depth is at least this high. 0 disables the check."

          integer :history_iv_scar_retry_days,
            default: 7,
            env: "HISTORY_IV_SCAR_RETRY_DAYS",
            min: 1,
            max: 30,
            label: "IV scar retry (days)",
            description: "After USGS confirms an interior hole has no fillable data, wait this many days before checking that station again (or sooner if a worse gap appears)."

          integer :usgs_request_pause_ms,
            default: 100,
            env: "USGS_REQUEST_PAUSE_MS",
            min: 0,
            max: 60_000,
            label: "USGS request pause (ms)",
            description: "Sleep between USGS API pages/requests to stay under rate limits."

          integer :nwps_request_pause_ms,
            default: 30_000,
            env: "NWPS_REQUEST_PAUSE_MS",
            min: 0,
            max: 300_000,
            label: "NWPS request pause (ms)",
            description: "Pause between NWPS HTTP calls during flood-stage sync."

          integer :nwps_detail_request_budget,
            default: 3,
            env: "NWPS_DETAIL_REQUEST_BUDGET",
            min: 0,
            max: 100,
            label: "NWPS detail request budget",
            description: "Max NWPS detail fetches allowed per flood-stage sync state pass."
        end
      end
    end
  end
end
