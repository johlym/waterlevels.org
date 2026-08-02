class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # More specific handlers must be registered after broader ones (rescue_from order).
  retry_on Usgs::Client::Error, wait: 30.seconds, attempts: 5
  retry_on Usgs::Client::RateLimitError, wait: :polynomially_longer, attempts: 10
end
