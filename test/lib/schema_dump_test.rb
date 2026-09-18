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

  test "schema.rb dumps every table without errors" do
    schema = SCHEMA_PATH.read

    refute_match(
      /Could not dump table/,
      schema,
      "schema.rb must not contain dump failures; restore from the last good dump instead of committing a broken db:schema:dump"
    )

    REQUIRED_TABLES.each do |table|
      assert_includes schema, %(create_table "#{table}"),
        "schema.rb must define #{table} so db:test:prepare can load it"
    end
  end
end
