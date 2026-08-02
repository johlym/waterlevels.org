module Gauges
  class MeasurementsComponent < ViewComponent::Base
    def initialize(measurements:)
      @measurements = Array(measurements)
    end

    def render?
      @measurements.any?
    end

    def has_temperature?
      @measurements.any? { |m| (m[:kind] || m["kind"]) == "temperature" }
    end
  end
end
