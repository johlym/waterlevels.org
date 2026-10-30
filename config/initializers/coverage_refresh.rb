# Coalesce continuous-coverage updates, and drop the per-request admin counter
# index when a Puma thread is reused.
module CoverageRefreshQueryGuard
  def log(sql, name = "SQL", binds = [], type_casted_binds = [], async: false, allow_retry: false, &block)
    TimeSeries.flush_coverage_refresh_before_query!(sql)
    super
  end
end

adapter = ActiveRecord::ConnectionAdapters::AbstractAdapter
adapter.prepend(CoverageRefreshQueryGuard) unless adapter.ancestors.include?(CoverageRefreshQueryGuard)

Rails.application.executor.to_run { AdminCounter.bust_request_cache! }
Rails.application.executor.to_complete do
  TimeSeries.flush_coverage_refresh!
  AdminCounter.bust_request_cache!
end
