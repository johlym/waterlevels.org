module Admin
  module Settings
    class HistoryRetention
      def self.register!
        Admin::SettingsRegistry.group :history_retention,
          title: "History retention",
          description: "High-impact continuous IV windows and upsert batching. Deep daily anchors stay code constants." do
          integer :continuous_retention_days,
            default: 35,
            min: 7,
            max: 90,
            label: "Continuous retention (days)",
            description: "How many days of high-resolution IV to keep in Postgres before archive rollup/prune."

          integer :continuous_gap_threshold_seconds,
            default: 2.hours.to_i,
            min: 60,
            max: 1.day.to_i,
            label: "Continuous gap threshold (seconds)",
            description: "IV spacing (or tip→now) above this is treated as a hole for IV repair / backfill."

          integer :continuous_freshness_days,
            default: 7,
            min: 1,
            max: 30,
            label: "Continuous freshness (days)",
            description: "Legacy “tip looks fresh enough” window used by some batch scopes and admin histograms."

          integer :continuous_upsert_batch,
            default: 500,
            min: 1,
            max: 10_000,
            label: "Continuous upsert batch",
            description: "Rows per continuous_observations upsert batch during history ingest."
        end
      end
    end
  end
end
