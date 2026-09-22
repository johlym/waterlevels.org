require "test_helper"

class SentryConfigTest < ActiveSupport::TestCase
  test "tracing and profiling are disabled for Telebugs" do
    config = Sentry.configuration

    assert_nil config.traces_sample_rate
    assert_nil config.traces_sampler
    assert_nil config.profiles_sample_rate
    refute config.tracing_enabled?
    refute config.profiling_enabled?
  end
end
