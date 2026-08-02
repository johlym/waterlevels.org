class ApplicationJob < ActiveJob::Base
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
end
