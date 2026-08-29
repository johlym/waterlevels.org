# frozen_string_literal: true

module Alerts
  # Above/below threshold for duration_minutes with hysteresis re-arm.
  class ThresholdEvaluator
    PARAMETER_KINDS = {
      "water_level" => "water_level",
      "discharge" => "discharge"
    }.freeze

    # Tips older than this are too stale to fire threshold emails (stricter than
    # map offline which uses MonitoringLocation::STALE_AFTER = 1.week).
    STALE_TIP_AFTER = 6.hours

    def initialize(rule:, location:, at: Time.current)
      @rule = rule
      @location = location
      @at = at
    end

    def should_fire?
      return false unless @rule.enabled?
      return false if @rule.in_cooldown?(@at)
      return false if tip_stale?

      series = series_for_parameter
      return false if series.blank?

      tip = current_value(series)
      return false if tip.nil?

      update_arm_state!(tip)

      return false unless @rule.armed?
      return false unless on_alert_side?(tip)

      continuous_holds?(series)
    end

    private

    def tip_stale?
      observed_at = @location.latest_observed_at
      observed_at ||= series_for_parameter&.latest_observation&.observed_at
      observed_at.blank? || observed_at < STALE_TIP_AFTER.before(@at)
    end

    def parameter
      @rule.param("parameter", "water_level").to_s
    end

    def op
      @rule.param("op", "above").to_s
    end

    def threshold
      @rule.param("value").to_d
    end

    def duration_minutes
      @rule.param("duration_minutes", 0).to_i
    end

    def hysteresis
      (@rule.param("hysteresis", 0) || 0).to_d
    end

    def series_for_parameter
      kind = PARAMETER_KINDS[parameter]
      return if kind.blank?

      @location.time_series.selected.find_by(measurement_kind: kind)
    end

    def current_value(series)
      series.latest_observation&.value || tip_from_location
    end

    def tip_from_location
      case parameter
      when "water_level" then @location.latest_water_level_value
      when "discharge" then @location.latest_discharge_value
      end
    end

    def on_alert_side?(value)
      v = value.to_d
      case op
      when "above" then v > threshold
      when "below" then v < threshold
      else false
      end
    end

    def cleared_with_hysteresis?(value)
      v = value.to_d
      case op
      when "above" then v <= (threshold - hysteresis)
      when "below" then v >= (threshold + hysteresis)
      else false
      end
    end

    def update_arm_state!(tip)
      if !@rule.armed? && cleared_with_hysteresis?(tip)
        @rule.rearm!
      end
    end

    def continuous_holds?(series)
      mins = duration_minutes
      return true if mins <= 0

      window_start = mins.minutes.before(@at)
      points = series.continuous_observations
        .where(observed_at: window_start..@at)
        .pluck(:value)

      return false if points.empty?
      return false unless points.size >= minimum_points_for(mins)

      points.all? { |v| on_alert_side?(v) }
    end

    # USGS IV is typically 15-minute; require enough samples to cover the window.
    def minimum_points_for(mins)
      return 1 if mins <= 15

      (mins / 15.0).ceil
    end
  end
end
