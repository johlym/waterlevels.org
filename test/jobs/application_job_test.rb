require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RateLimitProbeJob < ApplicationJob
    def perform
      raise Usgs::Client::RateLimitError, "probe"
    end
  end

  class NldiRateLimitProbeJob < ApplicationJob
    def perform
      raise Nldi::Client::RateLimitError, "probe"
    end
  end

  class ReadOnlyProbeJob < ApplicationJob
    def perform
      begin
        raise PG::ReadOnlySqlTransaction, "ERROR: cannot execute INSERT in a read-only transaction"
      rescue PG::ReadOnlySqlTransaction
        raise ActiveRecord::StatementInvalid, "PG::ReadOnlySqlTransaction: ERROR: cannot execute INSERT in a read-only transaction"
      end
    end
  end

  class OtherStatementInvalidProbeJob < ApplicationJob
    def perform
      raise ActiveRecord::StatementInvalid, "PG::SyntaxError: ERROR: syntax error"
    end
  end

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "discards USGS rate limit errors without re-enqueueing" do
    assert_no_enqueued_jobs only: RateLimitProbeJob do
      RateLimitProbeJob.perform_now
    end
  end

  test "discards NLDI rate limit errors without re-enqueueing" do
    assert_no_enqueued_jobs only: NldiRateLimitProbeJob do
      NldiRateLimitProbeJob.perform_now
    end
  end

  test "retries read-only database errors and trips the circuit" do
    assert_enqueued_with(job: ReadOnlyProbeJob) do
      ReadOnlyProbeJob.perform_now
    end
    assert DatabaseReadOnlyCircuit.open?
  end

  test "does not swallow unrelated StatementInvalid errors" do
    assert_raises(ActiveRecord::StatementInvalid) do
      OtherStatementInvalidProbeJob.perform_now
    end
    refute DatabaseReadOnlyCircuit.open?
  end
end
