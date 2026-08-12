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
    assert_match(/demo: done detail=ok elapsed=\d+\.\d/, output)
  end

  test "logger lines flatten logfmt strings into JSON fields" do
    io = StringIO.new
    log_io = StringIO.new
    logger = ActiveSupport::Logger.new(log_io)

    progress = SyncProgress.new("FloodStageSyncJob", io: io, logger: logger, every: 10)
    progress.step("phase=list_refresh done updated=1 elapsed=0.0s")

    logged = log_io.string
    data = JSON.parse(logged.lines.map(&:strip).reject(&:blank?).last)
    assert_equal "info", data["level"]
    assert_equal "sync.progress", data["event"]
    assert_equal "FloodStageSyncJob", data["job"]
    assert_equal "FloodStageSyncJob list_refresh done", data["message"]
    assert_equal "list_refresh", data["phase"]
    assert_equal "done", data["status"]
    assert_equal 1, data["updated"]
    assert_in_delta 0.0, data["elapsed"]
    refute_includes logged, '"msg":'
    assert_match(/FloodStageSyncJob: phase=list_refresh/, io.string)
  end

  test "logger lines accept structured kwargs" do
    io = StringIO.new
    log_io = StringIO.new
    logger = ActiveSupport::Logger.new(log_io)

    progress = SyncProgress.new("FloodStageSyncJob", io: io, logger: logger, every: 10)
    progress.step(phase: "list_refresh", status: "done", updated: 88, elapsed: 24.3)

    data = JSON.parse(log_io.string.lines.map(&:strip).reject(&:blank?).last)
    assert_equal "FloodStageSyncJob list_refresh done", data["message"]
    assert_equal "list_refresh", data["phase"]
    assert_equal 88, data["updated"]
    assert_in_delta 24.3, data["elapsed"]
    assert_match(/phase=list_refresh/, io.string)
  end
end
