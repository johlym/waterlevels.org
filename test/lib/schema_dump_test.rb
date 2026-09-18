# frozen_string_literal: true

require "test_helper"

class SchemaDumpTest < ActiveSupport::TestCase
  SCHEMA_PATH = Rails.root.join("db/schema.rb")

  # These tables all have jsonb columns. A broken `db:schema:dump` (seen on
  # Ruby 4.0.7 locally) comments them out with "Could not dump table" while
  # still emitting their foreign keys, so `db:test:prepare` fails with
  # PG::UndefinedTable.
  REQUIRED_TABLES = %w[
    admin_counters
    alert_deliveries
    alert_events
    alert_rules
    monitoring_locations
  ].freeze

  test "committed schema.rb dumps every table without errors" do
    schema = SCHEMA_PATH.read
    refute_dump_failures(schema)

    REQUIRED_TABLES.each do |table|
      assert_includes schema, %(create_table "#{table}"),
        "schema.rb must define #{table} so db:test:prepare can load it"
    end
  end

  test "schema dump still emits jsonb tables on this Ruby/JSON combo" do
    output = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, output)
    dumped = output.string
    refute_dump_failures(dumped)

    REQUIRED_TABLES.each do |table|
      assert_includes dumped, %(create_table "#{table}"),
        "db:schema:dump must emit #{table} (jsonb defaults must serialize)"
    end
  end

  private
    def refute_dump_failures(schema)
      refute_match(
        /Could not dump table/,
        schema,
        "schema dump must not skip jsonb tables; JSON 3.0 + ActiveSupport 8.1 is a known failure mode"
      )
    end
end
