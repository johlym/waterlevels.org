# frozen_string_literal: true

class AlertEvaluationBatchJob < ApplicationJob
  queue_as :notifications

  def perform
    location_ids = AlertEvaluationEnqueueBuffer.members
    return if location_ids.empty?

    location_ids.each do |location_id|
      evaluate_location(location_id)
    end
  ensure
    AlertEvaluationEnqueueBuffer.clear_flush_lock!
    # IDs added after members() was taken, or left behind by a failed
    # evaluate_location, must get another flush. Otherwise they sit until
    # KEY_TTL and are deleted without evaluation.
    AlertEvaluationEnqueueBuffer.schedule_flush! if AlertEvaluationEnqueueBuffer.any?
  end

  private

  def evaluate_location(location_id)
    AlertEvaluationJob.perform_now(location_id)
    AlertEvaluationEnqueueBuffer.remove(location_id)
  rescue StandardError => e
    Rails.logger.error(
      "[AlertEvaluationBatchJob] evaluation failed location_id=#{location_id} " \
      "#{e.class}: #{e.message}"
    )
  end
end
