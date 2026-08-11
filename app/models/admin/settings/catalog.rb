module Admin
  module Settings
    module Catalog
      module_function

      def register!
        Admin::SettingsRegistry.reset!
        PipelineJobs.register!
        IngestionThroughput.register!
        ArchiveFlags.register!
        HistoryRetention.register!
        MaintenanceActions.register!
      end
    end
  end
end
