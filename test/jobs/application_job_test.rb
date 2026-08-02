require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RateLimitProbeJob < ApplicationJob
    def perform
      raise Usgs::Client::RateLimitError, "probe"
    end
  end

  test "discards USGS rate limit errors without re-enqueueing" do
    assert_no_enqueued_jobs only: RateLimitProbeJob do
      RateLimitProbeJob.perform_now
    end
  end
end
