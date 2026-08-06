require "test_helper"

class EdgeCachePurgeBufferTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    EdgeCachePurgeBuffer.backend = EdgeCachePurgeBuffer::MemoryBackend.new
    clear_enqueued_jobs
  end

  teardown do
    EdgeCachePurgeBuffer.reset!
  end

  test "add and drain dedupe tags" do
    EdgeCachePurgeBuffer.add(%w[gauge:1 gauges map])
    EdgeCachePurgeBuffer.add(%w[gauge:2 gauges map])

    tags = EdgeCachePurgeBuffer.drain
    assert_equal %w[gauge:1 gauge:2 gauges map].sort, tags.sort
    assert_empty EdgeCachePurgeBuffer.drain
  end

  test "schedule_flush! enqueues at most one job until cleared" do
    assert EdgeCachePurgeBuffer.schedule_flush!(delay: 0)
    refute EdgeCachePurgeBuffer.schedule_flush!(delay: 0)
    assert_enqueued_jobs 1, only: EdgeCachePurgeJob

    EdgeCachePurgeBuffer.clear_flush_lock!
    assert EdgeCachePurgeBuffer.schedule_flush!(delay: 0)
    assert_enqueued_jobs 2, only: EdgeCachePurgeJob
  end
end
