require "test_helper"

class DatabaseReadOnlyCircuitTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "open? is false until tripped" do
    refute DatabaseReadOnlyCircuit.open?
    DatabaseReadOnlyCircuit.open!(ttl: 1.minute)
    assert DatabaseReadOnlyCircuit.open?
    DatabaseReadOnlyCircuit.clear!
    refute DatabaseReadOnlyCircuit.open?
  end

  test "read_only_error? detects PG read-only SQL transactions" do
    pg_error = PG::ReadOnlySqlTransaction.new("ERROR: cannot execute INSERT in a read-only transaction")
    assert DatabaseReadOnlyCircuit.read_only_error?(pg_error)

    wrapped = nil
    begin
      raise pg_error
    rescue PG::ReadOnlySqlTransaction
      begin
        raise ActiveRecord::StatementInvalid, "PG::ReadOnlySqlTransaction: #{pg_error.message}"
      rescue ActiveRecord::StatementInvalid => error
        wrapped = error
      end
    end

    assert DatabaseReadOnlyCircuit.read_only_error?(wrapped)
    refute DatabaseReadOnlyCircuit.read_only_error?(ActiveRecord::StatementInvalid.new("syntax error"))
  end
end
