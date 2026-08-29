# frozen_string_literal: true

module Alerts
  # Matches flood_category_change events against flood_category_change rules.
  class FloodEvaluator
    ORDER = %w[no_flooding action minor moderate major].freeze
    RANK = ORDER.each_with_index.to_h.freeze

    class << self
      def matches?(rule:, event:)
        return false unless rule.enabled?
        return false unless event.kind == AlertEventRecorder::FLOOD_KIND

        payload = event.payload || {}
        from = normalize(payload["from"])
        to = normalize(payload["to"])
        return false if from == to

        min_severity = normalize(rule.param("min_severity", "action"))
        notify_clear = ActiveModel::Type::Boolean.new.cast(rule.param("notify_clear", true))

        if to == "no_flooding"
          return false unless notify_clear

          return rank(from) >= rank(min_severity)
        end

        rank(to) >= rank(min_severity)
      end

      def normalize(value)
        key = Nwps::FloodCategories.normalize(value)
        key.presence || "no_flooding"
      end

      def rank(value)
        RANK.fetch(normalize(value), 0)
      end
    end
  end
end
