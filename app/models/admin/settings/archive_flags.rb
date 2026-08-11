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
            description: "When on, retention may delete legacy Postgres daily rows once present in the archive."
        end
      end
    end
  end
end
