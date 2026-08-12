require "test_helper"
require "stringio"

class SyncProgressTest < ActiveSupport::TestCase
  test "prints steps and periodic counts" do
    io = StringIO.new
    progress = SyncProgress.new("demo", io: io, logger: nil, every: 2)

    progress.step("working")
    progress.increment
    progress.increment
    progress.finish("ok")

    output = io.string
    assert_match(/demo: starting/, output)
    assert_match(/demo: working/, output)
    assert_match(/demo: 2 processed/, output)
    assert_match(/demo: done detail="ok" elapsed=\d+\.\ds/, output)
  end

  test "logger lines use JSON when AppLogging is enabled" do
    io = StringIO.new
    log_io = StringIO.new
    logger = ActiveSupport::Logger.new(log_io)

    enabled = AppLogging.method(:enabled?)
    AppLogging.define_singleton_method(:enabled?) { true }
    begin
      progress = SyncProgress.new("FloodStageSyncJob", io: io, logger: logger, every: 10)
      progress.step("phase=list_refresh done updated=1 elapsed=0.0s")
    ensure
      AppLogging.define_singleton_method(:enabled?, enabled)
    end

    logged = log_io.string
    data = JSON.parse(logged.lines.map(&:strip).reject(&:blank?).last)
    assert_equal "FloodStageSyncJob", data["job"]
    assert_equal "phase=list_refresh done updated=1 elapsed=0.0s", data["msg"]
    refute_includes logged, "FloodStageSyncJob: phase="
    assert_match(/FloodStageSyncJob: phase=list_refresh/, io.string)
  end
end
