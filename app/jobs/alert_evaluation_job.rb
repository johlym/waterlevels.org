# frozen_string_literal: true

class AlertEvaluationJob < ApplicationJob
  queue_as :notifications

  # Look back for events that may not yet have deliveries for matching rules.
  PENDING_WINDOW = 2.hours

  def perform(location_id)
    return unless AlertsConfig.enabled?

    location = MonitoringLocation.find_by(id: location_id)
    return unless location

    events = AlertEvent
      .where(monitoring_location_id: location.id)
      .where(occurred_at: PENDING_WINDOW.ago..)
      .order(:occurred_at)

    watches = StationWatch
      .joins(:subscriber)
      .merge(Subscriber.active)
      .where(monitoring_location_id: location.id)
      .includes(:alert_rules, :subscriber)

    return if watches.empty?

    events.each do |event|
      watches.each do |watch|
        evaluate_event!(event, watch, location)
      end
    end
  end

  private

  def evaluate_event!(event, watch, location)
    case event.kind
    when AlertEventRecorder::FLOOD_KIND
      watch.alert_rules.enabled.of_kind("flood_category_change").find_each do |rule|
        next if already_queued?(watch.subscriber, event, rule)
        next unless Alerts::FloodEvaluator.matches?(rule: rule, event: event)
        next if rule.in_cooldown?

        enqueue_delivery!(watch.subscriber, event, rule, "flood_category_change")
        rule.mark_fired!
      end
    when AlertEventRecorder::READING_KIND
      evaluate_reading_rules!(event, watch, location)
    end
  end

  def evaluate_reading_rules!(event, watch, location)
    previous = event.payload["from"]

    watch.alert_rules.enabled.of_kind("threshold").find_each do |rule|
      next unless parameter_matches?(rule, event)
      next if already_queued?(watch.subscriber, event, rule)
      next unless Alerts::ThresholdEvaluator.new(rule: rule, location: location).should_fire?

        enqueue_delivery!(watch.subscriber, event, rule, "threshold_crossed")
        rule.mark_fired!
    end

    watch.alert_rules.enabled.of_kind("rate_of_rise").find_each do |rule|
      next unless parameter_matches?(rule, event)
      next if already_queued?(watch.subscriber, event, rule)
      next unless Alerts::RateOfRiseEvaluator.new(rule: rule, location: location).should_fire?

      enqueue_delivery!(watch.subscriber, event, rule, "rate_of_rise")
      rule.mark_fired!
    end

    watch.alert_rules.enabled.of_kind("in_range").find_each do |rule|
      next unless parameter_matches?(rule, event)
      next if already_queued?(watch.subscriber, event, rule)
      next unless Alerts::InRangeEvaluator.new(
        rule: rule,
        location: location,
        previous_value: previous
      ).should_fire?

      enqueue_delivery!(watch.subscriber, event, rule, "in_range")
      rule.mark_fired!
    end
  end

  def parameter_matches?(rule, event)
    rule_param = rule.param("parameter").to_s
    return true if rule_param.blank?

    rule_param == event.payload["parameter"].to_s
  end

  def already_queued?(subscriber, event, rule)
    AlertDelivery.exists?(
      subscriber_id: subscriber.id,
      alert_event_id: event.id,
      alert_rule_id: rule.id
    )
  end

  def enqueue_delivery!(subscriber, event, rule, mailer_action)
    delivery = AlertDelivery.create!(
      subscriber: subscriber,
      alert_event: event,
      alert_rule: rule,
      mailer_action: mailer_action,
      status: "queued",
      metadata: { "kind" => rule.kind }
    )
    AlertDeliveryJob.perform_later(delivery.id)
  end
end
