module Mcp
  # One transaction, one connection. Postgres rejects writes and long queries.
  # ActiveRecord::Base.while_preventing_writes raises ReadOnlyError in-process
  # before a write is sent. Do not open another connection or thread inside.
  module ReadOnly
    module_function

    def during
      # Coverage updates are writes. Finish any deferred refresh before the
      # connection rejects them.
      TimeSeries.flush_coverage_refresh!
      ActiveRecord::Base.transaction do
        connection = ActiveRecord::Base.connection
        connection.execute("SET LOCAL transaction_read_only = ON")
        connection.execute("SET LOCAL statement_timeout = '3s'")
        ActiveRecord::Base.while_preventing_writes { yield }
      end
    end
  end
end
