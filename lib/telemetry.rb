# frozen_string_literal: true

# Thin helpers around the OpenTelemetry API for custom business spans.
# Auto-instrumentation covers Rails/HTTP/DB; use this for domain operations.
#
# Prefer +in_root_span+ for long-running ingest/sync work so Honeycomb always
# receives a root even when an ambient ActiveJob/Rake parent fails to export.
# Prefer +app.*+ attributes for domain dimensions you want to GROUP BY.
module Telemetry
  TRACER_NAME = "waterlevels"

  class << self
    def tracer
      OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
    end

    # Child span under the current context (HTTP handlers, nested steps).
    def in_span(name, attributes: {}, kind: :internal)
      tracer.in_span(name.to_s, kind: kind) do |span|
        apply_attributes(span, attributes)
        begin
          yield span
        rescue StandardError => e
          mark_exception(span, e)
          raise
        end
      end
    end

    # Always-root span for top-level business operations (ingest/sync).
    # Links to any ambient parent so enqueue → worker correlation remains.
    def in_root_span(name, attributes: {}, kind: :internal)
      span = nil
      span = tracer.start_root_span(
        name.to_s,
        attributes: nil,
        links: ambient_parent_links,
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
      span&.finish
    end

    def add_attributes(attributes)
      apply_attributes(OpenTelemetry::Trace.current_span, attributes)
    end

    def record_exception(error, slug: nil)
      mark_exception(OpenTelemetry::Trace.current_span, error, slug: slug)
    end

    private

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
