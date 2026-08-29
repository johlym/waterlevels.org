# frozen_string_literal: true

class AlertQuietScanJob < ApplicationJob
  queue_as :notifications

  def perform
    return unless AlertsConfig.enabled?

    Alerts::QuietStationDetector.scan!
  end
end
