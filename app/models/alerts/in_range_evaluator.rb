# frozen_string_literal: true

module Alerts
  # Phase F: enter / leave a discharge or water_level corridor.
  class InRangeEvaluator
    PARAMETER_KINDS = {
      "water_level" => "water_level",
      "discharge" => "discharge"
    }.freeze

    def initialize(rule:, location:, previous_value: nil, at: Time.current)
      @rule = rule
      @location = location
      @previous_value = previous_value
      @at = at
    end

    def should_fire?
      return false unless @rule.enabled?
      return false if @rule.in_cooldown?(@at)

      current = current_value
      return false if current.nil?

      now_in = in_range?(current)
      was_in = @previous_value.nil? ? nil : in_range?(@previous_value)

      case on_mode
      when "enter"
        was_in == false && now_in
      when "leave"
        was_in == true && !now_in
      when "both"
        !was_in.nil? && was_in != now_in
      else
        false
      end
    end

    private

    def parameter
      @rule.param("parameter", "discharge").to_s
    end

    def on_mode
      @rule.param("on", "enter").to_s
    end

    def range_min
      @rule.param("min").to_d
    end

    def range_max
      @rule.param("max").to_d
    end

    def in_range?(value)
      v = value.to_d
      v >= range_min && v <= range_max
    end

    def current_value
      series = series_for_parameter
      return series.latest_observation&.value if series

      tip_from_location
    end

    def tip_from_location
      case parameter
      when "water_level" then @location.latest_water_level_value
      when "discharge" then @location.latest_discharge_value
      end
    end

    def series_for_parameter
      kind = PARAMETER_KINDS[parameter]
      return if kind.blank?

      @location.time_series.selected.find_by(measurement_kind: kind)
    end
  end
end
