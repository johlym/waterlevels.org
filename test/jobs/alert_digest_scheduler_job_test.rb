# frozen_string_literal: true

require "test_helper"

class AlertDigestSchedulerJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_alerts = ENV["ALERTS_ENABLED"]
    ENV["ALERTS_ENABLED"] = "1"
    travel_to Time.find_zone("America/New_York").local(2026, 8, 29, 7, 5, 0)
    @location = create(
      :monitoring_location,
      latest_water_level_value: 10,
      latest_observed_at: 1.hour.ago
    )
    @subscriber = create(
      :subscriber,
      time_zone: "America/New_York",
      digest_hour: 7,
      digest_minute: 0,
      digest_enabled: true,
      digest_last_sent_on: nil
    )
    create(:station_watch, subscriber: @subscriber, monitoring_location: @location)
  end

  teardown do
    travel_back
    if @previous_alerts
      ENV["ALERTS_ENABLED"] = @previous_alerts
    else
      ENV.delete("ALERTS_ENABLED")
    end
  end

  test "enqueues digest delivery for due subscribers" do
    assert_enqueued_with(job: AlertDeliveryJob) do
      AlertDigestSchedulerJob.perform_now
    end

    delivery = AlertDelivery.last
    assert_equal "digest", delivery.mailer_action
    assert delivery.metadata["snapshot"].present?
    assert_equal Time.find_zone("America/New_York").local(2026, 8, 29).to_date,
                 @subscriber.reload.digest_last_sent_on
  end

  test "does not double-send same local day" do
    AlertDigestSchedulerJob.perform_now
    assert_no_difference("AlertDelivery.count") do
      AlertDigestSchedulerJob.perform_now
    end
  end
end
