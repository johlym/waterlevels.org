module Gauges
  class MeasurementsComponent < ViewComponent::Base
    def initialize(measurements:, site_number: nil)
      @measurements = Array(measurements)
      @site_number = site_number
    end

    def render?
      @measurements.any?
    end

    def has_temperature?
      @measurements.any? { |m| (m[:kind] || m["kind"]) == "temperature" }
    end

    def featured_mention
      return if @site_number.blank?

      TrendHighlights.mention_for(@site_number)
    end
  end
end
