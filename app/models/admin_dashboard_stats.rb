# Live ops snapshot for the password-gated /admin dashboard.
# Job-finish / tip-refresh summaries are written by sync POROs (Redis +
# process-local fallback); everything else is computed on each request.
class AdminDashboardStats
  TIP_REFRESH_CACHE_KEY = "admin:last_tip_refresh".freeze
  JOB_CACHE_KEYS = {
    tip_refresh: TIP_REFRESH_CACHE_KEY,
    catalog_sync: "admin:last_catalog_sync",
    flood_sync: "admin:last_flood_sync",
    prune: "admin:last_prune",
    daily_archive_export: "admin:last_daily_archive_export"
  }.freeze
  TIP_REFRESH_TTL = 7.days
  APPROX_COUNT_THRESHOLD = SiteStats::APPROX_COUNT_THRESHOLD
  class << self
    def snapshot
      new.snapshot
    end

    def record_tip_refresh!(stations_updated:, series_upserted:, finished_at: Time.current, state: nil)
      record_job_finish!(
        :tip_refresh,
        finished_at: finished_at,
        stations_updated: stations_updated.to_i,
        series_upserted: series_upserted.to_i,
        state: state.presence
      )
    end

    def record_job_finish!(name, finished_at: Time.current, **extra)
      key = cache_key_for!(name)
      payload = extra.merge(finished_at: finished_at.iso8601)
      write_job_payload(key, payload)
      payload
    end

    def last_tip_refresh
      last_job(:tip_refresh)
    end

    def last_job(name)
      key = cache_key_for!(name)
      redis_read_job(key) || memory_jobs[key]
    end

    def clear_tip_refresh!
      clear_jobs!
    end

    def clear_jobs!
      self.memory_jobs = {}
      redis_with_rescue { |r| r.del(*JOB_CACHE_KEYS.values) }
    end

    private

    def memory_jobs
      @memory_jobs ||= {}
    end

    def memory_jobs=(value)
      @memory_jobs = value || {}
    end

    def cache_key_for!(name)
      JOB_CACHE_KEYS.fetch(name.to_sym)
    end

    def write_job_payload(key, payload)
      memory_jobs[key] = payload
      redis_with_rescue do |r|
        r.set(key, payload.to_json, ex: TIP_REFRESH_TTL.to_i)
      end
    end

    def redis_read_job(key)
      raw = redis_with_rescue { |r| r.get(key) }
      return if raw.blank?

      JSON.parse(raw, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    def redis_with_rescue
      yield redis
    rescue StandardError => e
      Rails.logger.warn("[AdminDashboardStats] redis #{e.class}: #{e.message}")
      nil
    end

    def redis
      @redis ||= Redis.new(RedisConfig.options)
    end
  end

  def snapshot
    tip = self.class.last_tip_refresh || {}
    last_station = MonitoringLocation.order(updated_at: :desc).first
    stations_by_state = MonitoringLocation.active.group(:state_code).count
    needing_history_by_state = MonitoringLocation.needing_history_backfill.group(:state_code).count
    needing_deep_by_state = MonitoringLocation.needing_deep_history_backfill.group(:state_code).count
    missing_year_by_state = missing_year_history_by_state

    {
      station_count: MonitoringLocation.active.count,
      stations_needing_history: needing_history_by_state.values.sum,
      stations_needing_deep_history: needing_deep_by_state.values.sum,
      stations_missing_year_history: missing_year_by_state.values.sum,
      stations_history_ready: [
        MonitoringLocation.active.count -
          needing_history_by_state.values.sum -
          needing_deep_by_state.values.sum,
        0
      ].max,
      stale_station_count: MonitoringLocation.active.count - MonitoringLocation.active.not_stale.count,
      flood_alert_count: MonitoringLocation.flood_alert.count,
      nwps_matched_count: MonitoringLocation.active.where(nwps_matched: true).count,
      measurement_count: measurement_count,
      continuous_observation_count: approximate_or_exact_count(ContinuousObservation),
      daily_observation_count: approximate_or_exact_count(DailyObservation),
      peak_observation_count: approximate_or_exact_count(PeakObservation),
      updates_today: ContinuousObservation.where(observed_at: pacific_today_range).count,
      continuous_last_24h: ContinuousObservation.where(observed_at: 24.hours.ago..).count,
      continuous_last_7d: ContinuousObservation.where(observed_at: 7.days.ago..).count,
      tip_freshness: tip_freshness_histogram,
      per_state: per_state_rows(
        stations_by_state,
        needing_history_by_state,
        needing_deep_by_state,
        missing_year_by_state
      ),
      history_backfill_locks: count_prefixed_redis_keys(HistoryBackfillLock::KEY_PREFIX),
      history_backfill_cooldowns: count_prefixed_redis_keys(HistoryBackfillLock::COOLDOWN_PREFIX),
      last_station_updated: last_station && {
        id: last_station.id,
        site_number: last_station.site_number,
        display_name: last_station.display_name,
        state_code: last_station.state_code,
        path_state: last_station.path_state,
        to_param: last_station.to_param,
        updated_at: last_station.updated_at,
        latest_observed_at: last_station.latest_observed_at
      },
      last_tip_refresh_stations_updated: tip[:stations_updated],
      last_tip_refresh_series_upserted: tip[:series_upserted],
      last_tip_refresh_finished_at: parse_time(tip[:finished_at]),
      last_tip_refresh_state: tip[:state],
      last_catalog_sync_at: parse_time(self.class.last_job(:catalog_sync)&.dig(:finished_at)),
      last_catalog_sync_state: self.class.last_job(:catalog_sync)&.dig(:state),
      last_flood_sync_at: parse_time(self.class.last_job(:flood_sync)&.dig(:finished_at)),
      last_flood_sync_state: self.class.last_job(:flood_sync)&.dig(:state),
      last_prune_at: parse_time(self.class.last_job(:prune)&.dig(:finished_at)),
      tip_circuit_open: Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY),
      history_circuits: history_circuit_statuses,
      history_keys_exhausted: Usgs::HistoryKeyPool.exhausted?,
      usgs_request_budgets: Usgs::HourlyRequestBudget.dashboard_snapshot,
      database_read_only: DatabaseReadOnlyCircuit.open?,
      sidekiq: sidekiq_stats
    }
  end

  private

  def measurement_count
    approximate_or_exact_count(ContinuousObservation) +
      approximate_or_exact_count(DailyObservation) +
      approximate_or_exact_count(PeakObservation)
  end

  def approximate_or_exact_count(model)
    estimate = connection.select_value(
      "SELECT reltuples::bigint FROM pg_class WHERE oid = #{connection.quote(model.table_name)}::regclass"
    ).to_i
    return estimate if estimate >= APPROX_COUNT_THRESHOLD

    model.count
  end

  def tip_freshness_histogram
    scope = MonitoringLocation.active
    now = Time.current
    {
      under_1h: scope.where(latest_observed_at: 1.hour.ago..).count,
      h1_to_6h: scope.where(latest_observed_at: 6.hours.ago...1.hour.ago).count,
      h6_to_24h: scope.where(latest_observed_at: 24.hours.ago...6.hours.ago).count,
      d1_to_7d: scope.where(latest_observed_at: 7.days.ago...24.hours.ago).count,
      stale: scope.where("latest_observed_at IS NULL OR latest_observed_at < ?", now - 7.days).count
    }
  end

  def per_state_rows(
    stations_by_state,
    needing_history_by_state,
    needing_deep_by_state,
    missing_year_by_state
  )
    codes = (
      stations_by_state.keys +
      needing_history_by_state.keys +
      needing_deep_by_state.keys +
      missing_year_by_state.keys
    ).uniq.sort
    codes.map do |code|
      station_count = stations_by_state[code].to_i
      needing_history = needing_history_by_state[code].to_i
      needing_deep = needing_deep_by_state[code].to_i
      missing_year = missing_year_by_state[code].to_i
      {
        state_code: code,
        state_name: state_name_for(code),
        station_count: station_count,
        needing_history: needing_history,
        # Subset of phase-1: selected series lack daily near the ~1y anchor.
        missing_year_history: missing_year,
        needing_deep_history: needing_deep,
        # Mutually exclusive with the two backlog columns.
        history_ready: [ station_count - needing_history - needing_deep, 0 ].max
      }
    end
  end

  # Active stations whose selected series still lack daily points near the
  # ~1-year anchor. Overlaps phase-1 backlog; never includes deep-only rows.
  def missing_year_history_by_state
    year_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    missing_year_series = TimeSeries.selected.where.not(
      id: DailyObservation.where(observed_on: ..year_anchor).select(:time_series_id)
    )
    MonitoringLocation.active
      .where(id: missing_year_series.select(:monitoring_location_id))
      .group(:state_code)
      .count
  end

  def state_name_for(code)
    Usgs::StateCodes.name_for(code)
  rescue ArgumentError, KeyError
    code.to_s.upcase
  end

  def count_prefixed_redis_keys(prefix)
    count = 0
    cursor = "0"
    self.class.send(:redis_with_rescue) do |r|
      loop do
        cursor, keys = r.scan(cursor, match: "#{prefix}*", count: 1_000)
        count += keys.size
        break if cursor.to_s == "0"
      end
      count
    end || 0
  end

  def history_circuit_statuses
    Usgs::HistoryKeyPool::ENTRIES.map do |entry|
      budget = Usgs::HourlyRequestBudget.status_for(
        entry[:circuit_key],
        configured: ENV[entry[:env]].to_s.strip.present?,
        env: entry[:env]
      )
      {
        key: entry[:circuit_key],
        env: entry[:env],
        configured: budget[:configured],
        open: budget[:circuit_open],
        used: budget[:used],
        remaining: budget[:remaining],
        budget: budget[:budget],
        soft_capped: budget[:soft_capped]
      }
    end
  end

  def sidekiq_stats
    require "sidekiq/api"
    stats = Sidekiq::Stats.new
    {
      enqueued: stats.enqueued,
      retry_size: stats.retry_size,
      dead_size: stats.dead_size,
      processed: stats.processed,
      failed: stats.failed,
      queues: Sidekiq::Queue.all.map { |q| [ q.name, q.size ] }.to_h
    }
  rescue StandardError => e
    { error: e.message }
  end

  def pacific_today_range
    zone = Time.find_zone!(SiteStats::UPDATES_TIME_ZONE)
    zone.now.all_day
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def connection
    ActiveRecord::Base.connection
  end
end
