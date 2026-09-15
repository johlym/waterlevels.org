# frozen_string_literal: true

class AlertEvaluationBatchJob < ApplicationJob
  queue_as :notifications

  def perform
    location_ids = AlertEvaluationEnqueueBuffer.drain
    return if location_ids.empty?

    # Drain removes IDs from Redis before evaluation. Track remaining so a
    # mid-loop failure can re-queue unfinished work instead of silently
    # dropping alert evaluations for watched stations.
    remaining = location_ids.dup
    begin
      location_ids.each do |location_id|
        AlertEvaluationJob.perform_now(location_id)
        remaining.shift
      end
    rescue StandardError
      remaining.each { |id| AlertEvaluationEnqueueBuffer.add(id) }
      raise
    end
  ensure
    AlertEvaluationEnqueueBuffer.clear_flush_lock!
  end
end
