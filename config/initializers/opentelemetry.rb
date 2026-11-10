# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require Rails.root.join("lib/telemetry")

# Manual pipeline spans only. Auto-instrumentation is intentionally not loaded:
# Rack, ActiveJob, Sidekiq, and Faraday spans burned the Honeycomb free-tier
# event budget and do not answer duration, queue, or completeness questions.
# Do not add use_all or per-HTTP / per-row spans.
#
# One pipeline.work / pipeline.queue / pipeline.pressure / pipeline.coverage
# span is one billed event. Do not sample pipeline.work — the slow tail is the
# signal. If a future change emits per-row or per-HTTP spans, sample those and
# keep pipeline.work at 100%.
#
# Export only when OTEL_TRACES_EXPORTER / the OTLP endpoint is configured.
# Tests stay offline.
if Rails.env.test?
  ENV["OTEL_TRACES_EXPORTER"] ||= "none"
end

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "waterlevels-org")
end
