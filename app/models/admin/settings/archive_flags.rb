module Admin
  module Settings
    class ArchiveFlags
      def self.register!
        Admin::SettingsRegistry.group :daily_archive,
          title: "Daily archive",
          description: "Runtime levers for R2/local daily archive reads, writes, and prune. Store credentials stay in ENV." do
          boolean :daily_archive_reads,
            default: false,
            env: "DAILY_ARCHIVE_READS",
            label: "Archive reads",
            description: "When on (and a store is configured), 1y/3y charts read daily history from the archive."

          boolean :daily_archive_dual_write,
            default: true,
            env: "DAILY_ARCHIVE_DUAL_WRITE",
            label: "Archive writes",
            description: "When on, ingest writes dailies to the archive. Set off to pause archive writes without undeploying."

          boolean :daily_archive_prune,
            default: false,
            env: "DAILY_ARCHIVE_PRUNE",
            label: "Prune Postgres dailies",
            description: "When on, export and retention may delete leftover Postgres daily rows once present in the archive."

          boolean :daily_archive_vacuum,
            default: true,
            env: "DAILY_ARCHIVE_VACUUM",
            label: "VACUUM after archive deletes",
            description: "When on, export / drain / retention run VACUUM (ANALYZE) on observation tables after a large delete (or when dead tuples already exceed the threshold)."

          integer :daily_archive_vacuum_min_deleted,
            default: 10_000,
            min: 0,
            max: 10_000_000,
            env: "DAILY_ARCHIVE_VACUUM_MIN_DELETED",
            label: "VACUUM delete threshold",
            description: "Run VACUUM when this run deleted at least this many rows, or pg_stat n_dead_tup is already this high. 0 = vacuum any table that has deletes or dead tuples."
        end
      end
    end
  end
end
