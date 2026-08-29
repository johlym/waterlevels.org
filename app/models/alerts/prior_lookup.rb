# frozen_string_literal: true

module Alerts
  # Short-window prior from continuous_observations (TrendComparison-style).
  class PriorLookup
    class << self
      def value_for(series, hours:, at: Time.current)
        return if series.blank? || hours.blank? || hours.to_f <= 0

        cutoff_at = at - hours.to_f.hours
        lookup_continuous_prior(series, cutoff_at)
      end

      def for_series(series, hours:, current_value:, at: Time.current)
        prior = value_for(series, hours: hours, at: at)
        TrendComparison.new(
          current_value: current_value,
          prior_value: prior,
          label: "#{hours.to_f}h"
        )
      end

      private

      def lookup_continuous_prior(series, cutoff_at)
        if series.association(:continuous_observations).loaded?
          series.continuous_observations
            .select { |o| o.observed_at <= cutoff_at }
            .max_by(&:observed_at)
            &.value
        else
          series.continuous_observations
            .where("observed_at <= ?", cutoff_at)
            .order(observed_at: :desc)
            .limit(1)
            .pick(:value)
        end
      end
    end
  end
end
