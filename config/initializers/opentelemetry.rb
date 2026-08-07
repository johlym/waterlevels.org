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
  c.use_all
end
