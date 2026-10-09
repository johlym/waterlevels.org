module Mcp
  # Process-local cap of one in-flight tools/call. initialize, tools/list, and
  # ping are not counted. Release in ensure (and from test teardown).
  module Inflight
    LOCK = Mutex.new

    module_function

    def try_acquire
      LOCK.synchronize do
        return false if @held

        @held = true
        true
      end
    end

    def release
      LOCK.synchronize { @held = false }
    end
  end
end
