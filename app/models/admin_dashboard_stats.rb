# Live ops snapshot for the password-gated /admin dashboard.
# Tip-refresh totals are written by LatestObservationSync (Redis + process-local
# fallback); everything else is computed from the DB / circuits on each request.
class AdminDashboardStats
  TIP_REFRESH_CACHE_KEY = "admin:last_tip_refresh".freeze
  TIP_REFRESH_TTL = 7.days
  APPROX_COUNT_THRESHOLD = SiteStats::APPROX_COUNT_THRESHOLD

  class << self
    def snapshot
      new.snapshot
    end

    def record_tip_refresh!(stations_updated:, series_upserted:, finished_at: Time.current, state: nil)
      payload = {
        stations_updated: stations_updated.to_i,
        series_upserted: series_upserted.to_i,
        finished_at: finished_at.iso8601,
        state: state.presence
      }
      write_tip_refresh(payload)
      payload
    end

    def last_tip_refresh
      redis_read_tip_refresh || memory_tip_refresh
    end

    def clear_tip_refresh!
      self.memory_tip_refresh = nil
      redis_with_rescue { |r| r.del(TIP_REFRESH_CACHE_KEY) }
    end

    private

    attr_accessor :memory_tip_refresh

    def write_tip_refresh(payload)
      self.memory_tip_refresh = payload
      redis_with_rescue do |r|
        r.set(TIP_REFRESH_CACHE_KEY, payload.to_json, ex: TIP_REFRESH_TTL.to_i)
      end
    end

    def redis_read_tip_refresh
      raw = redis_with_rescue { |r| r.get(TIP_REFRESH_CACHE_KEY) }
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

    {
      station_count: MonitoringLocation.active.count,
      stations_needing_history: MonitoringLocation.needing_history_backfill.count,
      stations_needing_deep_history: MonitoringLocation.needing_deep_history_backfill.count,
      stale_station_count: MonitoringLocation.active.count - MonitoringLocation.active.not_stale.count,
      flood_alert_count: MonitoringLocation.flood_alert.count,
      nwps_matched_count: MonitoringLocation.active.where(nwps_matched: true).count,
      measurement_count: measurement_count,
      continuous_observation_count: approximate_or_exact_count(ContinuousObservation),
      daily_observation_count: approximate_or_exact_count(DailyObservation),
      peak_observation_count: approximate_or_exact_count(PeakObservation),
      updates_today: ContinuousObservation.where(observed_at: pacific_today_range).count,
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
      last_tip_refresh_finished_at: tip[:finished_at] && Time.zone.parse(tip[:finished_at].to_s),
      last_tip_refresh_state: tip[:state],
      tip_circuit_open: Usgs::RateLimitCircuit.open?(Usgs::RateLimitCircuit::TIP_KEY),
      history_circuits: history_circuit_statuses,
      history_keys_exhausted: Usgs::HistoryKeyPool.exhausted?,
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

  def history_circuit_statuses
    Usgs::HistoryKeyPool::ENTRIES.map do |entry|
      {
        key: entry[:circuit_key],
        env: entry[:env],
        configured: ENV[entry[:env]].to_s.strip.present?,
        open: Usgs::RateLimitCircuit.open?(entry[:circuit_key])
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

  def connection
    ActiveRecord::Base.connection
  end
end
