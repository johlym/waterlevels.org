# frozen_string_literal: true

# Manual OpenTelemetry spans for the data pipeline.
#
# Honeycomb bills every span and every span link as an event. Keep one root
# span per question and put phase timings on it. Do not open child spans for
# HTTP calls, per-parameter work, or per-station steps inside a run.
#
# Duration is the span's own duration_ms. Do not copy it onto the span.
module Telemetry
  TRACER_NAME = "waterlevels"
  WORK_SPAN = "pipeline.work"
  QUEUE_SPAN = "pipeline.queue"
  PRESSURE_SPAN = "pipeline.pressure"
  COVERAGE_SPAN = "pipeline.coverage"

  class << self
    def tracer
      OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
    end

    # One root span for a pipeline run. Sets pipeline.outcome=ok until
    # skip! or an exception marks it otherwise.
    def work(lane, attributes = {})
      attrs = { signal: "work", lane: lane.to_s, outcome: "ok" }.merge(attributes)
      in_root_span(WORK_SPAN, attributes: pipeline_attributes(attrs)) do |span|
        yield span
      end
    end

    # Open a work span only when the caller is not already inside one
    # (rake tasks and model tests). Nested pipeline code must not emit
    # a second span for the same run.
    def ensure_work(lane, attributes = {})
      if work_span?
        note(attributes) if attributes.present?
        yield OpenTelemetry::Trace.current_span
      else
        work(lane, attributes) { |span| yield span }
      end
    end

    # Gauge-like root event. Not linked to the current span: a link is
    # billed as its own Honeycomb event.
    def gauge(name, signal:, **attributes)
      attrs = pipeline_attributes(attributes)
      attrs["pipeline.signal"] = signal.to_s
      in_root_span(name, attributes: attrs, link_parent: false) { |span| span }
    end

    def note(attributes = {})
      add_attributes(pipeline_attributes(attributes))
    end

    def skip!(reason)
      note(outcome: "skipped", skip_reason: reason.to_s)
    end

    # Wall time for a named phase, accumulated on the current span as
    # pipeline.phase.<name>_ms.
    def phase(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      if started
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        add_milliseconds("pipeline.phase.#{name}_ms", elapsed_ms)
      end
    end

    def note_slowest_state(state, elapsed_ms)
      span = OpenTelemetry::Trace.current_span
      return unless span&.recording?

      elapsed_ms = elapsed_ms.to_i
      bucket = (accumulators[span.object_id] ||= {})
      previous = bucket["pipeline.slowest_state_ms"]
      return if previous && elapsed_ms < previous

      bucket["pipeline.slowest_state_ms"] = elapsed_ms
      span.set_attribute("pipeline.slowest_state", state.to_s)
      span.set_attribute("pipeline.slowest_state_ms", elapsed_ms)
    end

    # Time one upstream HTTP call onto the current work span. No child span.
    def time_http
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      if started
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        record_http(elapsed_ms)
      end
    end

    def record_http(elapsed_ms)
      return unless OpenTelemetry::Trace.current_span&.recording?

      add_milliseconds("pipeline.http_ms", elapsed_ms)
      add_count("pipeline.http_count", 1)
    end

    def add_milliseconds(key, elapsed_ms)
      add_count(key, elapsed_ms.to_i)
    end

    def add_count(key, amount)
      span = OpenTelemetry::Trace.current_span
      return unless span&.recording?

      attribute = pipeline_key(key)
      bucket = (accumulators[span.object_id] ||= {})
      bucket[attribute] = bucket[attribute].to_i + amount.to_i
      span.set_attribute(attribute, bucket[attribute])
    end

    def accumulated(key)
      span = OpenTelemetry::Trace.current_span
      return 0 unless span&.recording?

      accumulators.dig(span.object_id, pipeline_key(key)).to_i
    end

    # Child span under the current context. Pipeline code uses work /
    # ensure_work instead; this remains for tests and any non-pipeline caller.
    def in_span(name, attributes: {}, kind: :internal)
      tracer.in_span(name.to_s, kind: kind) do |span|
        apply_attributes(span, attributes)
        begin
          yield span
        rescue StandardError => e
          mark_exception(span, e)
          raise
        ensure
          clear_accumulator(span)
        end
      end
    end

    # Always-root span. Links to an ambient parent only when link_parent
    # is true and a parent is recording.
    def in_root_span(name, attributes: {}, kind: :internal, link_parent: true)
      span = nil
      span = tracer.start_root_span(
        name.to_s,
        attributes: nil,
        links: link_parent ? ambient_parent_links : nil,
        kind: kind
      )
      OpenTelemetry::Trace.with_span(span) do
        apply_attributes(span, attributes)
        begin
          yield span
        rescue StandardError => e
          mark_exception(span, e)
          raise
        end
      end
    ensure
      clear_accumulator(span)
      span&.finish
    end

    def add_attributes(attributes)
      apply_attributes(OpenTelemetry::Trace.current_span, attributes)
    end

    def record_exception(error, slug: nil)
      mark_exception(OpenTelemetry::Trace.current_span, error, slug: slug)
    end

    def work_span?
      span = OpenTelemetry::Trace.current_span
      return false unless span&.recording?
      return false unless span.respond_to?(:attributes)

      span.attributes&.[]("pipeline.signal") == "work"
    end

    private

    def pipeline_attributes(attributes)
      attributes.each_with_object({}) do |(key, value), out|
        next if value.nil?

        out[pipeline_key(key)] = value
      end
    end

    def pipeline_key(key)
      text = key.to_s
      text.start_with?("pipeline.") ? text : "pipeline.#{text}"
    end

    def accumulators
      Thread.current[:telemetry_accumulators] ||= {}
    end

    def clear_accumulator(span)
      return unless span

      accumulators.delete(span.object_id)
    end

    def ambient_parent_links
      parent = OpenTelemetry::Trace.current_span
      return nil unless parent&.context&.valid? && parent.recording?

      [ OpenTelemetry::Trace::Link.new(parent.context, { "link.reason" => "ambient_parent" }) ]
    end

    def apply_attributes(span, attributes)
      return unless span&.recording?

      attributes.each do |key, value|
        next if value.nil?

        span.set_attribute(key.to_s, otel_value(value))
      end
    end

    def mark_exception(span, error, slug: nil)
      return unless span&.recording?

      span.record_exception(error)
      span.status = OpenTelemetry::Trace::Status.error(error.message.to_s)
      span.set_attribute("error", true)
      span.set_attribute("pipeline.outcome", "error")
      span.set_attribute("exception.slug", slug) if slug.present?
    end

    def otel_value(value)
      case value
      when String, Integer, Float, TrueClass, FalseClass
        value
      when Symbol
        value.to_s
      else
        value.to_s
      end
    end
  end
end
