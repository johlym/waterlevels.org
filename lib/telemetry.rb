# frozen_string_literal: true

# Thin helpers around the OpenTelemetry API for custom business spans.
# Auto-instrumentation covers Rails/HTTP/DB; use this for domain operations.
module Telemetry
  TRACER_NAME = "waterlevels"

  class << self
    def tracer
      OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
    end

    # Wrap a business operation in a child span. Prefer low-cardinality attributes
    # for GROUP BY (state, parameter_code) plus ids for debugging.
    def in_span(name, attributes: {})
      tracer.in_span(name.to_s) do |span|
        apply_attributes(span, attributes)
        begin
          yield span
        rescue StandardError => e
          mark_exception(span, e)
          raise
        end
      end
    end

    def add_attributes(attributes)
      apply_attributes(OpenTelemetry::Trace.current_span, attributes)
    end

    def record_exception(error, slug: nil)
      mark_exception(OpenTelemetry::Trace.current_span, error, slug: slug)
    end

    private

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
