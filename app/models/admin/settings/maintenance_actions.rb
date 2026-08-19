module Admin
  module Settings
    class MaintenanceActions
      def self.register!
        Admin::SettingsRegistry.group :maintenance,
          title: "Maintenance",
          description: "One-shot cache, circuit, and lock clears. Prefer routine actions first; danger actions can restart load." do
          action :invalidate_api_caches,
            label: "Invalidate API response caches",
            description: "Bump ApiResponseCache generations for map and gauge observation JSON." do
            ApiResponseCache.invalidate_after_sync!
            :ok
          end

          action :bust_site_stats,
            label: "Bust site stats",
            description: "Clear the homepage / marketing SiteStats snapshot so the next read recomputes." do
            SiteStats.bust!
            :ok
          end

          action :bust_admin_dashboard_caches,
            label: "Bust admin dashboard caches",
            description: "Clear cached admin section payloads and the inventory AdminCounter so the next read recomputes." do
            AdminDashboardStats.bust_backfill_cache!
            :ok
          end

          action :clear_listing_caches,
            label: "Clear station / state / alerts listings",
            description: "Delete warm station snapshots, per-state listing payloads, and the alerts listing cache." do
            StationSnapshotCache.clear!
            StateListingCache.clear!
            AlertsListingCache.clear!
            :ok
          end

          action :clear_sitemap_and_og_caches,
            label: "Clear sitemap & OG image caches",
            description: "Drop cached sitemap XML and Open Graph PNG payloads." do
            Sitemap.clear!
            OgImage.clear!
            :ok
          end

          action :flush_pending_edge_purges,
            label: "Flush pending Cloudflare purges",
            description: "Drain the coalesced edge purge tag buffer and send a purge request now." do
            EdgeCacheInvalidation.flush_pending!
            :ok
          end

          action :purge_common_edge_tags,
            label: "Purge common edge tags",
            description: "Purge home, map, alerts, gauges, and states Cache-Tags on Cloudflare (no-ops without credentials)." do
            EdgeCacheInvalidation.new.purge!(%w[home map alerts gauges states])
            :ok
          end

          action :clear_usgs_rate_limit_circuits,
            label: "Clear USGS rate-limit circuits",
            description: "Close tip and all history purpose circuits so jobs resume hitting USGS.",
            danger: true,
            confirm: "Clear all USGS rate-limit circuits? Jobs may immediately resume API traffic." do
            ids = [ Usgs::RateLimitCircuit::TIP_KEY ] + Usgs::HistoryKeyPool::PURPOSES.values.map { |meta| meta[:circuit_key] }
            ids.uniq.each { |id| Usgs::RateLimitCircuit.clear!(id) }
            :ok
          end

          action :clear_db_read_only_circuit,
            label: "Clear DB read-only circuit",
            description: "Close the database read-only circuit so sync/backfill jobs stop short-circuiting.",
            danger: true,
            confirm: "Clear the database read-only circuit?" do
            DatabaseReadOnlyCircuit.clear!
            :ok
          end

          action :clear_history_backfill_locks,
            label: "Clear history backfill locks & cooldowns",
            description: "Delete all history_backfill lock and cooldown keys. Stations may be enqueued again immediately.",
            danger: true,
            confirm: "Clear all history backfill locks and cooldowns? This can restart backfill load." do
            HistoryBackfillLock.clear_all!
            :ok
          end

          action :clear_iv_repair_locks,
            label: "Clear IV repair locks & cooldowns",
            description: "Delete all iv_repair lock and cooldown keys shared by tip and scar lanes.",
            danger: true,
            confirm: "Clear all IV repair locks and cooldowns? This can restart repair load." do
            IvRepairLock.clear_all!
            :ok
          end

          action :enqueue_daily_archive_drain,
            label: "Drain leftover Postgres dailies",
            description: "Enqueue DailyArchiveDrainJob to delete leftover daily_observations already present in the archive, then VACUUM if needed.",
            confirm: "Enqueue leftover daily drain now?" do
            DailyArchiveDrainJob.perform_later
            :enqueued
          end

          action :clear_daily_archive_checkpoints,
            label: "Clear daily archive checkpoints",
            description: "Reset export and retention resume cursors so the next run starts from the beginning.",
            danger: true,
            confirm: "Clear daily archive export and retention checkpoints?" do
            DailyArchive::ExportCheckpoint.clear!
            DailyArchive::RetentionCheckpoint.clear!
            :ok
          end

          action :clear_admin_job_finish_keys,
            label: "Clear admin job-finish records",
            description: "Wipe AdminCounter rows that power the dashboard Jobs panel and IV candidate counts.",
            danger: true,
            confirm: "Clear admin last-job finish records?" do
            AdminDashboardStats.clear_jobs!
            :ok
          end
        end
      end
    end
  end
end
