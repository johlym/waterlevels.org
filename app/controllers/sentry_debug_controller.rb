# frozen_string_literal: true

# Temporary controller used to verify Sentry error capture end to end.
# Remove after the first-error verification succeeds.
class SentryDebugController < ActionController::Base
  def show
    raise "Sentry test error #{Time.current.utc.iso8601}"
  end
end
