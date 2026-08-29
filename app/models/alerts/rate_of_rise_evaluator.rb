# frozen_string_literal: true

module Alerts
  # Phase F: fire when water_level or discharge rises by +delta over window_hours.
  class RateOfRiseEvaluator
    PARAMETER_KINDS = {
      "water_level" => "water_level",
      "discharge" => "discharge"
    }.freeze

    def initialize(rule:, location:, at: Time.current)
      @rule = rule
      @location = location
      @at = at
    end

    def should_fire?
      return false unless @rule.enabled?
      return false if @rule.in_cooldown?(@at)

      series = series_for_parameter
      return false if series.blank?

      current = series.latest_observation&.value
      return false if current.nil?

      prior = PriorLookup.value_for(series, hours: window_hours, at: @at)
      return false if prior.nil?

      (current.to_d - prior.to_d) >= delta
    end

    private

    def parameter
      @rule.param("parameter", "water_level").to_s
    end

    def window_hours
      @rule.param("window_hours", 3).to_f
    end

    def delta
      @rule.param("delta", 0).to_d
    end

    def series_for_parameter
      kind = PARAMETER_KINDS[parameter]
      return if kind.blank?

      @location.time_series.selected.find_by(measurement_kind: kind)
    end
  end
end
