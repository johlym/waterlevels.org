class ApplicationJob < ActiveJob::Base
  # Raised when Postgres rejects writes during upgrades/failover. Distinct from
  # ActiveRecord::ReadOnlyError (which is about readonly *records*).
  class DatabaseReadOnlyError < StandardError; end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # More specific handlers must be registered after broader ones (rescue_from order).
  retry_on Usgs::Client::Error, wait: 30.seconds, attempts: 5
  # Rate limits must not retry into a Sidekiq backlog that keeps draining the pool.
  discard_on Usgs::Client::RateLimitError do |job, error|
    Rails.logger.warn(
      "Discarded #{job.class.name} job_id=#{job.job_id} after USGS rate limit: #{error.message}"
    )
  end
  discard_on Nldi::Client::RateLimitError do |job, error|
    Rails.logger.warn(
      "Discarded #{job.class.name} job_id=#{job.job_id} after NLDI rate limit: #{error.message}"
    )
  end

  # Heroku Postgres upgrades (and similar) flip the primary read-only for a few
  # minutes. Sidekiq's default 25-attempt exponential backoff would otherwise
  # leave a multi-day retry backlog; keep waits short and capped instead.
  retry_on DatabaseReadOnlyError, wait: 2.minutes, attempts: 15 do |job, error|
    Rails.logger.warn(
      "Gave up #{job.class.name} job_id=#{job.job_id} after read-only database: #{error.message}"
    )
  end

  around_perform do |_job, block|
    block.call
  rescue ActiveRecord::StatementInvalid => e
    if DatabaseReadOnlyCircuit.read_only_error?(e)
      DatabaseReadOnlyCircuit.open!
      raise DatabaseReadOnlyError, e.message
    end
    raise
  end
end
