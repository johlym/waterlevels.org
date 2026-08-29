# frozen_string_literal: true

module Alerts
  # Detect stations that stopped reporting, then resumed.
  class QuietStationDetector
    DEFAULT_QUIET_HOURS = 6

    def self.scan!(quiet_after: DEFAULT_QUIET_HOURS.hours, at: Time.current)
      new(quiet_after: quiet_after, at: at).scan!
    end

    def initialize(quiet_after:, at:)
      @quiet_after = quiet_after
      @at = at
    end

    def scan!
      return [] unless AlertsConfig.enabled?

      watched_ids = StationWatch.distinct.pluck(:monitoring_location_id)
      return [] if watched_ids.empty?

      quiet = []
      resumed = []

      MonitoringLocation.where(id: watched_ids).find_each do |location|
        observed_at = location.latest_observed_at
        if observed_at.blank? || observed_at < @quiet_after.before(@at)
          event = AlertEventRecorder.quiet_station!(location: location, observed_at: observed_at, at: @at)
          quiet << event if event
        else
          # Resume: tip is fresh again after a prior quiet event in the window.
          prior_quiet = AlertEvent
            .where(monitoring_location_id: location.id, kind: AlertEventRecorder::QUIET_KIND)
            .where(occurred_at: 7.days.ago(@at)..)
            .order(occurred_at: :desc)
            .first
          next unless prior_quiet

          already_resumed = AlertEvent.exists?(
            monitoring_location_id: location.id,
            kind: AlertEventRecorder::RESUME_KIND,
            occurred_at: prior_quiet.occurred_at..
          )
          next if already_resumed

          event = AlertEventRecorder.resume_station!(location: location, observed_at: observed_at, at: @at)
          resumed << event if event
        end
      end

      { quiet: quiet.compact, resumed: resumed.compact }
    end
  end
end
