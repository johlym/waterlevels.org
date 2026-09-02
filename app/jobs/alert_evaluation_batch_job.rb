# frozen_string_literal: true

class AlertEvaluationBatchJob < ApplicationJob
  queue_as :notifications

  def perform
    location_ids = AlertEvaluationEnqueueBuffer.drain
    return if location_ids.empty?

    location_ids.each do |location_id|
      AlertEvaluationJob.perform_now(location_id)
    end
  ensure
    AlertEvaluationEnqueueBuffer.clear_flush_lock!
  end
end
