# frozen_string_literal: true

require "test_helper"

class AlertEvaluationEnqueueBufferTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    AlertEvaluationEnqueueBuffer.backend = AlertEvaluationEnqueueBuffer::MemoryBackend.new
    clear_enqueued_jobs
  end

  teardown do
    AlertEvaluationEnqueueBuffer.reset!
  end

  test "add and drain dedupe location ids" do
    AlertEvaluationEnqueueBuffer.add(1)
    AlertEvaluationEnqueueBuffer.add(2)
    AlertEvaluationEnqueueBuffer.add(1)

    ids = AlertEvaluationEnqueueBuffer.drain
    assert_equal [ 1, 2 ].sort, ids.sort
    assert_empty AlertEvaluationEnqueueBuffer.drain
  end

  test "schedule_flush! enqueues at most one batch job until cleared" do
    assert AlertEvaluationEnqueueBuffer.schedule_flush!(delay: 0)
    refute AlertEvaluationEnqueueBuffer.schedule_flush!(delay: 0)
    assert_enqueued_jobs 1, only: AlertEvaluationBatchJob

    AlertEvaluationEnqueueBuffer.clear_flush_lock!
    assert AlertEvaluationEnqueueBuffer.schedule_flush!(delay: 0)
    assert_enqueued_jobs 2, only: AlertEvaluationBatchJob
  end
end
