require "test_helper"

module DailyArchive
  class TableMaintenanceTest < ActiveSupport::TestCase
    setup do
      AppSetting.delete_all
      AppConfig.bust!
    end

    teardown do
      AppSetting.delete_all
      AppConfig.bust!
    end

    test "tables_to_vacuum uses this-run deletes against the threshold" do
      AppConfig.write!(:daily_archive_vacuum_min_deleted, 10)

      assert_equal [], TableMaintenance.tables_to_vacuum(
        daily_deleted: 9,
        continuous_deleted: 0,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 0 }
      )
      assert_equal [ "daily_observations" ], TableMaintenance.tables_to_vacuum(
        daily_deleted: 10,
        continuous_deleted: 0,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 0 }
      )
      assert_equal [ "continuous_observations" ], TableMaintenance.tables_to_vacuum(
        daily_deleted: 0,
        continuous_deleted: 11,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 0 }
      )
    end

    test "tables_to_vacuum also fires on leftover dead tuples" do
      AppConfig.write!(:daily_archive_vacuum_min_deleted, 100)

      assert_equal [ "daily_observations" ], TableMaintenance.tables_to_vacuum(
        daily_deleted: 1,
        continuous_deleted: 0,
        dead_tuples: { "daily_observations" => 100, "continuous_observations" => 0 }
      )
    end

    test "threshold 0 vacuums any table with deletes or dead tuples" do
      AppConfig.write!(:daily_archive_vacuum_min_deleted, 0)

      assert_equal [], TableMaintenance.tables_to_vacuum(
        daily_deleted: 0,
        continuous_deleted: 0,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 0 }
      )
      assert_equal [ "daily_observations", "continuous_observations" ], TableMaintenance.tables_to_vacuum(
        daily_deleted: 1,
        continuous_deleted: 0,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 2 }
      )
    end

    test "vacuum! skips inside the test environment" do
      result = TableMaintenance.vacuum!([ "daily_observations" ])
      assert_equal false, result[:vacuumed]
      assert_equal "test", result[:skipped]
    end

    test "vacuum! rejects tables outside the observation allowlist" do
      error = assert_raises(ArgumentError) do
        TableMaintenance.send(:vacuum_allowlisted!, [ "schema_migrations" ])
      end
      assert_match(/schema_migrations/, error.message)
    end

    test "vacuum_after_deletes! no-ops below the threshold" do
      AppConfig.write!(:daily_archive_vacuum_min_deleted, 50_000)
      result = TableMaintenance.vacuum_after_deletes!(
        daily_deleted: 3,
        continuous_deleted: 4,
        dead_tuples: { "daily_observations" => 0, "continuous_observations" => 0 }
      )
      assert_equal false, result[:vacuumed]
      assert_equal "none", result[:skipped]
    end
  end
end
