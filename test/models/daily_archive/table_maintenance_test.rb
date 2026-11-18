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

    def with_direct_connection(fake)
      eigen = TableMaintenance.singleton_class
      eigen.alias_method(:__orig_checkout_direct_connection, :checkout_direct_connection)
      eigen.define_method(:checkout_direct_connection) { fake }
      yield
    ensure
      eigen.alias_method(:checkout_direct_connection, :__orig_checkout_direct_connection)
      eigen.remove_method(:__orig_checkout_direct_connection)
      eigen.send(:private, :checkout_direct_connection)
    end

    def with_database_env(values)
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
      yield
    ensure
      previous.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
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

    test "vacuum! uses the direct connection when PS_DATABASE_DIRECT_URL is set" do
      AppConfig.write!(:daily_archive_vacuum, true)
      sql = []
      fake = Object.new
      fake.define_singleton_method(:execute) { |statement| sql << statement }

      with_database_env(
        "PS_DATABASE_URL" => "postgres://app@example.psdb.cloud:6432/waterlevels",
        "PS_DATABASE_DIRECT_URL" => "postgres://migrate@example.psdb.cloud:5432/waterlevels"
      ) do
        with_direct_connection(fake) do
          result = TableMaintenance.vacuum!([ "continuous_observations" ], force: true)
          assert_equal true, result[:vacuumed]
          assert_equal [ "continuous_observations" ], result[:tables]
        end
      end

      assert_equal [
        "SET statement_timeout TO 0",
        "VACUUM (ANALYZE) continuous_observations",
        "SET statement_timeout TO DEFAULT"
      ], sql
    end

    test "vacuum! skips a pooler when no direct url is configured" do
      AppConfig.write!(:daily_archive_vacuum, true)
      with_database_env(
        "PS_DATABASE_URL" => "postgres://app@example.psdb.cloud:6432/waterlevels?sslmode=require",
        "PS_DATABASE_DIRECT_URL" => nil
      ) do
        result = TableMaintenance.vacuum!([ "daily_observations" ], force: true)
        assert_equal false, result[:vacuumed]
        assert_equal "pooler", result[:skipped]
      end
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
