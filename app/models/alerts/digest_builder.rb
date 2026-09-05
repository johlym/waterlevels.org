# frozen_string_literal: true

module Alerts
  # Snapshot of watched stations for a subscriber's daily digest.
  class DigestBuilder
    def initialize(subscriber)
      @subscriber = subscriber
    end

    def build
      {
        subscriber_id: @subscriber.id,
        email: @subscriber.email,
        time_zone: @subscriber.time_zone,
        generated_at: Time.current.iso8601,
        stations: station_snapshots
      }
    end

    private

    def station_snapshots
      watches = @subscriber.station_watches
        .includes(:monitoring_location, :alert_rules)
        .joins(:alert_rules)
        .merge(AlertRule.enabled.of_kind("digest"))
        .distinct

      watches.filter_map do |watch|
        next unless digest_included?(watch)

        snapshot_for(watch.monitoring_location, label: watch.label)
      end
    end

    def digest_included?(watch)
      rule = watch.rule_for("digest")
      return false unless rule&.enabled?

      ActiveModel::Type::Boolean.new.cast(rule.param("include", true))
    end

    def snapshot_for(location, label:)
      level_series = location.time_series.selected.find_by(measurement_kind: "water_level")
      delta_24h = nil
      if level_series && location.latest_water_level_value.present? && location.latest_observed_at.present?
        delta_24h = TrendComparison.for_series(
          level_series,
          current_value: location.latest_water_level_value,
          observed_at: location.latest_observed_at
        ).delta
      end

      {
        monitoring_location_id: location.id,
        site_number: location.site_number,
        name: location.display_name.presence || location.name,
        label: label,
        state_code: location.state_code,
        url: gauge_url_for(location),
        water_level: cast(location.latest_water_level_value),
        water_level_unit: location.latest_water_level_unit,
        discharge: cast(location.latest_discharge_value),
        discharge_unit: location.latest_discharge_unit,
        delta_24h: cast(delta_24h),
        flood_category: location.flood_category.presence || "no_flooding",
        flood_category_label: location.flood_category_short_label,
        stale: location.stale?,
        latest_observed_at: location.latest_observed_at&.iso8601
      }
    end

    def gauge_url_for(location)
      opts = Rails.application.config.action_mailer.default_url_options || {}
      Rails.application.routes.url_helpers.gauge_url(
        state: location.path_state,
        site_number_slug: location.to_param,
        **opts
      )
    end

    def cast(value)
      return if value.nil?

      value.to_d
    end
  end
end

