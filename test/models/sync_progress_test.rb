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
    assert_match(/demo: done \(ok\)/, output)
  end
end
