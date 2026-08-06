class EdgeCachePurgeJob < ApplicationJob
  queue_as :default

  def perform
    EdgeCacheInvalidation.flush_pending!
  ensure
    EdgeCachePurgeBuffer.clear_flush_lock!
  end
end
