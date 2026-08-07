# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"
require Rails.root.join("lib/telemetry")

# Keep the test suite offline and deterministic. Export only when explicitly
# configured (Honeycomb OTLP endpoint / console exporter).
if Rails.env.test?
  ENV["OTEL_TRACES_EXPORTER"] ||= "none"
end

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "waterlevels")
  # force_flush on ActiveJob reduces missing-root traces when long ingest jobs
  # export child batches before the job wrapper span ends. Sidekiq/ActiveJob use
  # :link so workers start a fresh root instead of dangling on a sampled-out parent.
  c.use_all(
    "OpenTelemetry::Instrumentation::ActiveJob" => {
      force_flush: true,
      propagation_style: :link,
      span_naming: :job_class
    },
    "OpenTelemetry::Instrumentation::Sidekiq" => {
      propagation_style: :link,
      span_naming: :job_class
    }
  )
end
