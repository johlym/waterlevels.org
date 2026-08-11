module Admin
  module Settings
    class AdminDashboard
      def self.register!
        Admin::SettingsRegistry.group :admin_dashboard,
          title: "Admin dashboard",
          description: "Levers for /admin inventory Counters and statement timeouts on heavy aggregates." do
          boolean :admin_dashboard_counters_enabled,
            default: true,
            label: "Inventory Counters refresh",
            description: "When off, AdminDashboardCountersJob skips and sync jobs do not enqueue inventory refreshes. Existing Counter rows stay until the next successful refresh."

          integer :admin_dashboard_statement_timeout_ms,
            default: 12_000,
            env: "ADMIN_DASHBOARD_STATEMENT_TIMEOUT_MS",
            min: 1_000,
            max: 28_000,
            label: "Dashboard statement timeout (ms)",
            description: "Postgres statement_timeout for /admin section aggregates. Keep under Heroku’s 30s H12."
        end
      end
    end
  end
end
