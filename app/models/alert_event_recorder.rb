# frozen_string_literal: true

# Records durable alert_events from flood / tip sync transitions.
# Idempotent via dedupe_key; optionally enqueues AlertEvaluationJob.
class AlertEventRecorder
  FLOOD_KIND = "flood_category_change"
  READING_KIND = "reading_change"
  QUIET_KIND = "quiet_station"
  RESUME_KIND = "resume_station"

  class << self
    def flood_category_change!(location:, from:, to:, observed_at:)
      from_n = normalize_flood(from)
      to_n = normalize_flood(to)
      return if from_n == to_n

      at = observed_at.presence || Time.current
      event = AlertEvent.record!(
        location: location,
        kind: FLOOD_KIND,
        occurred_at: at,
        payload: {
          "from" => from_n,
          "to" => to_n,
          "observed_at" => at.iso8601
        },
        dedupe_key: "flood:#{location.id}:#{from_n}:#{to_n}:#{at.to_i}"
      )
      enqueue_evaluation!(location, event) if event
      event
    end

    def reading_change!(location:, parameter:, from:, to:, unit:, observed_at:)
      return unless meaningful_change?(from, to)

      at = observed_at.presence || Time.current
      param = parameter.to_s
      event = AlertEvent.record!(
        location: location,
        kind: READING_KIND,
        occurred_at: at,
        payload: {
          "parameter" => param,
          "from" => cast_number(from),
          "to" => cast_number(to),
          "unit" => unit.to_s.presence,
          "observed_at" => at.iso8601
        },
        dedupe_key: "reading:#{location.id}:#{param}:#{at.to_i}"
      )
      enqueue_evaluation!(location, event) if event
      event
    end

    def quiet_station!(location:, observed_at:, at: Time.current)
      tip_i = observed_at&.to_i || 0
      event = AlertEvent.record!(
        location: location,
        kind: QUIET_KIND,
        occurred_at: at,
        payload: {
          "latest_observed_at" => observed_at&.iso8601,
          "detected_at" => at.iso8601
        },
        dedupe_key: "quiet:#{location.id}:#{tip_i}:#{at.to_date}"
      )
      enqueue_evaluation!(location, event) if event
      event
    end

    def resume_station!(location:, observed_at:, at: Time.current)
      tip_i = observed_at&.to_i || 0
      event = AlertEvent.record!(
        location: location,
        kind: RESUME_KIND,
        occurred_at: at,
        payload: {
          "latest_observed_at" => observed_at&.iso8601,
          "detected_at" => at.iso8601
        },
        dedupe_key: "resume:#{location.id}:#{tip_i}"
      )
      enqueue_evaluation!(location, event) if event
      event
    end

    private

    def enqueue_evaluation!(location, event)
      return unless AlertsConfig.enabled?

      AlertEvaluationJob.perform_later(location.id, event.id)
    end

    def normalize_flood(value)
      key = Nwps::FloodCategories.normalize(value)
      key.presence || "no_flooding"
    end

    def meaningful_change?(from, to)
      return false if from.nil? && to.nil?
      return true if from.nil? || to.nil?

      from.to_d != to.to_d
    end

    def cast_number(value)
      return if value.nil?

      value.to_d
    end
  end
end
