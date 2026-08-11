# Live ops snapshot for the password-gated /admin dashboard.
# Job-finish / tip-refresh summaries are written by sync POROs (Redis +
# process-local fallback). The dashboard loads section snapshots via Turbo
# Frames so the shell can render before heavy aggregates finish; backfill
# aggregates are cached with race_condition_ttl so parallel section requests
# share one compute instead of stampedes.
require "set"

class AdminDashboardStats
  TIP_REFRESH_CACHE_KEY = "admin:last_tip_refresh".freeze
  JOB_CACHE_KEYS = {
    tip_refresh: TIP_REFRESH_CACHE_KEY,
    catalog_sync: "admin:last_catalog_sync",
    flood_sync: "admin:last_flood_sync",
    prune: "admin:last_prune",
    daily_archive_export: "admin:last_daily_archive_export",
    iv_repair_batch: "admin:last_iv_repair_batch",
    iv_repair: "admin:last_iv_repair"
  }.freeze
  # Last successful IV-repair eligibility scan size. Kept separate from
  # iv_repair_batch job-finish so skipped runs (circuit/queue/Sunday) do not
  # wipe the pipeline "Need IV repair" figure — and so /admin never re-runs
  # MonitoringLocation.iv_repair_candidate_ids (tip_sync_gap + continuous scans).
  IV_REPAIR_CANDIDATES_CACHE_KEY = "admin:iv_repair_candidates".freeze
  TIP_REFRESH_TTL = 7.days
  APPROX_COUNT_THRESHOLD = SiteStats::APPROX_COUNT_THRESHOLD
  SECTIONS = %i[core pipeline growth jobs states health].freeze
  # Cheap sections first so the sequential frame loader warms UI quickly, then
  # core (which fills the backfill cache), then the remaining heavy panels.
  SECTION_LOAD_ORDER = %i[jobs health core pipeline growth states].freeze
  BACKFILL_CACHE_KEY = "admin_dashboard/backfill_aggregates/v4".freeze
  BACKFILL_TTL = 10.minutes
  BACKFILL_RACE_TTL = 30.seconds
  # Bump when a section payload shape changes so deploys do not serve stale
  # hashes that crash the matching partial (Turbo then shows "Content missing").
  SECTION_CACHE_KEY_PREFIX = "admin_dashboard/section/v7".freeze
  SECTION_TTL = 2.minutes
  SECTION_RACE_TTL = 15.seconds
  REDIS_SCAN_MAX_ITERATIONS = 50
  # Keep well under Heroku's 30s H12 so a slow aggregate frees the Puma thread.
  STATEMENT_TIMEOUT_MS = Integer(ENV.fetch("ADMIN_DASHBOARD_STATEMENT_TIMEOUT_MS", "12000"))

  class << self
    def snapshot
      new.snapshot
    end

    def section(name)
      key = name.to_sym
      unless SECTIONS.include?(key)
        raise ArgumentError, "Unknown admin dashboard section: #{name.inspect}"
      end

      Rails.cache.fetch(
        "#{SECTION_CACHE_KEY_PREFIX}/#{key}",
        expires_in: SECTION_TTL,
        race_condition_ttl: SECTION_RACE_TTL
      ) do
        new.section(key)
      end
    end

    def sections
      SECTIONS
    end

    def section_load_order
      SECTION_LOAD_ORDER
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
      if name.to_sym == :iv_repair_batch && extra.key?(:candidates)
        record_iv_repair_candidates!(extra[:candidates], scanned_at: finished_at)
      end
      payload
    end

    def record_iv_repair_candidates!(count, scanned_at: Time.current)
      write_job_payload(
        IV_REPAIR_CANDIDATES_CACHE_KEY,
        {
          count: count.to_i,
          scanned_at: scanned_at.iso8601
        }
      )
    end

    def last_iv_repair_candidates_payload
      redis_read_job(IV_REPAIR_CANDIDATES_CACHE_KEY) || memory_jobs[IV_REPAIR_CANDIDATES_CACHE_KEY]
    end

    # Candidate station count from the last completed eligibility scan.
    # Prefer the dedicated key (survives skipped batch finishes); fall back to
    # the last iv_repair_batch job payload when present.
    def last_iv_repair_candidates
      payload = last_iv_repair_candidates_payload
      return payload[:count].to_i if payload&.key?(:count)

      batch = last_job(:iv_repair_batch) || {}
      return batch[:candidates].to_i if batch.key?(:candidates)

      nil
    end

    def last_iv_repair_candidates_scanned_at
      payload = last_iv_repair_candidates_payload
      return parse_cached_time(payload[:scanned_at]) if payload&.key?(:scanned_at)

      batch = last_job(:iv_repair_batch) || {}
      return parse_cached_time(batch[:finished_at]) if batch.key?(:candidates)

      nil
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
      redis_with_rescue { |r| r.del(*JOB_CACHE_KEYS.values, IV_REPAIR_CANDIDATES_CACHE_KEY) }
    end

    def parse_cached_time(value)
      return if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def bust_backfill_cache!
      Rails.cache.delete(BACKFILL_CACHE_KEY)
      SECTIONS.each { |name| Rails.cache.delete("#{SECTION_CACHE_KEY_PREFIX}/#{name}") }
    end

    def warm_backfill!
      new.send(:backfill_aggregates)
    end

    def with_statement_timeout(ms = STATEMENT_TIMEOUT_MS)
      connection = ActiveRecord::Base.connection
      previous = connection.select_value("SHOW statement_timeout")
      # Quote the coerced integer so Brakeman does not flag string interpolation.
      connection.execute("SET statement_timeout TO #{connection.quote(Integer(ms))}")
      yield
    ensure
      if previous
        connection.execute("SET statement_timeout TO #{connection.quote(previous)}")
      end
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
    SECTIONS.each_with_object({}) { |name, hash| hash.merge!(public_send(:"#{name}_section")) }
  end

  def section(name)
    key = name.to_sym
    unless SECTIONS.include?(key)
      raise ArgumentError, "Unknown admin dashboard section: #{name.inspect}"
    end

    public_send(:"#{key}_section")
  end

  def core_section
    tip = tip_refresh_payload
    last_station = MonitoringLocation.order(updated_at: :desc).first
    continuous_count = approximate_or_exact_count(ContinuousObservation)
    daily_count = approximate_or_exact_count(DailyObservation)
    peak_count = approximate_or_exact_count(PeakObservation)
    archive_daily_count = DailyArchive.cold_archive_point_count
    backfill = backfill_aggregates

    {
      station_count: backfill[:station_count],
      stations_needing_history: backfill[:stations_needing_history],
      stations_missing_year_history: backfill[:stations_missing_year_history],
      measurement_count: continuous_count + daily_count + peak_count + archive_daily_count,
      continuous_observation_count: continuous_count,
      daily_observation_count: daily_count,
      peak_observation_count: peak_count,
      archive_daily_observation_count: archive_daily_count,
      daily_archive_shard_count: DailyArchive.shard_count,
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
      last_tip_refresh_state: tip[:state]
    }
  end

  def pipeline_section
    backfill = backfill_aggregates
    active_count = backfill[:station_count]
    site = SiteStats.snapshot

    {
      stations_needing_deep_history: backfill[:stations_needing_deep_history],
      stations_history_ready: backfill[:stations_history_ready],
      # Last batch eligibility scan — never live needing_iv_repair / tip_sync_gap.
      stations_needing_iv_repair: self.class.last_iv_repair_candidates.to_i,
      iv_repair_candidates_scanned_at: self.class.last_iv_repair_candidates_scanned_at,
      stale_station_count: active_count - MonitoringLocation.active.not_stale.count,
      flood_alert_count: site[:flood_alert_count],
      nwps_matched_count: MonitoringLocation.active.where(nwps_matched: true).count,
      updates_today: site[:updates_today],
      history_backfill_locks: count_prefixed_redis_keys(HistoryBackfillLock::KEY_PREFIX),
      history_backfill_cooldowns: count_prefixed_redis_keys(HistoryBackfillLock::COOLDOWN_PREFIX),
      iv_repair_locks: count_prefixed_redis_keys(IvRepairLock::KEY_PREFIX),
      iv_repair_cooldowns: count_prefixed_redis_keys(IvRepairLock::COOLDOWN_PREFIX)
    }
  end

  def growth_section
    {
      continuous_last_24h: ContinuousObservation.where(observed_at: 24.hours.ago..).count,
      continuous_last_7d: ContinuousObservation.where(observed_at: 7.days.ago..).count,
      tip_freshness: tip_freshness_histogram
    }
  end

  def jobs_section
    tip = tip_refresh_payload
    catalog = self.class.last_job(:catalog_sync) || {}
    flood = self.class.last_job(:flood_sync) || {}
    prune = self.class.last_job(:prune) || {}
    archive_export = self.class.last_job(:daily_archive_export) || {}
    iv_repair_batch = self.class.last_job(:iv_repair_batch) || {}
    iv_repair = self.class.last_job(:iv_repair) || {}

    {
      last_tip_refresh_finished_at: parse_time(tip[:finished_at]),
      last_tip_refresh_state: tip[:state],
      last_catalog_sync_at: parse_time(catalog[:finished_at]),
      last_catalog_sync_state: catalog[:state],
      last_flood_sync_at: parse_time(flood[:finished_at]),
      last_flood_sync_state: flood[:state],
      last_prune_at: parse_time(prune[:finished_at]),
      last_prune_usgs_ensured: prune[:usgs_ensured].to_i,
      last_prune_derived: prune[:derived].to_i,
      last_prune_retrying: prune[:retrying].to_i,
      last_prune_gaps_alerted: prune[:gaps_alerted].to_i,
      last_prune_iv_deleted: (prune[:iv_deleted] || prune[:continuous_deleted]).to_i,
      last_prune_iv_blocked: prune[:iv_prune_blocked].to_i,
      last_prune_daily_deleted: prune[:daily_deleted].to_i,
      last_prune_daily_blocked: prune[:daily_prune_blocked].to_i,
      last_daily_archive_export_at: parse_time(archive_export[:finished_at]),
      last_daily_archive_export_series: archive_export[:series],
      last_daily_archive_export_points: archive_export[:points],
      last_iv_repair_batch_at: parse_time(iv_repair_batch[:finished_at]),
      last_iv_repair_batch_enqueued: iv_repair_batch[:enqueued].to_i,
      last_iv_repair_batch_candidates: iv_repair_batch[:candidates].to_i,
      last_iv_repair_batch_skip_reason: iv_repair_batch[:skip_reason],
      last_iv_repair_batch_workers: iv_repair_batch[:workers],
      last_iv_repair_batch_queue_depth_after: iv_repair_batch[:queue_depth_after],
      last_iv_repair_at: parse_time(iv_repair[:finished_at]),
      last_iv_repair_site_number: iv_repair[:site_number],
      last_iv_repair_continuous_upserted: iv_repair[:continuous_upserted].to_i,
      last_iv_repair_still_needs: iv_repair[:still_needs],
      last_iv_repair_elapsed_s: iv_repair[:elapsed_s]
    }
  end

  def states_section
    { per_state: backfill_aggregates[:per_state] }
  end

  def health_section
    key_statuses = Usgs::HistoryKeyPool.dashboard_statuses
    {
      tip_circuit_open: key_statuses[:tip][:open],
      usgs_keys: key_statuses,
      history_circuits: key_statuses[:history],
      history_keys_exhausted: key_statuses[:exhausted],
      database_read_only: DatabaseReadOnlyCircuit.open?,
      sidekiq: sidekiq_stats
    }
  end

  private

  def tip_refresh_payload
    self.class.last_tip_refresh || {}
  end

  def backfill_aggregates
    @backfill_aggregates ||= Rails.cache.fetch(
      BACKFILL_CACHE_KEY,
      expires_in: BACKFILL_TTL,
      race_condition_ttl: BACKFILL_RACE_TTL
    ) do
      compute_backfill_aggregates
    end
  end

  # One pass over selected series + small coverage sets — avoids nested
  # needing_history/deep ActiveRecord scopes that each seq-scan observations.
  def compute_backfill_aggregates
    year_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    deep_anchor = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    continuous_since = HistoryIngestion::CONTINUOUS_FRESHNESS.ago
    daily_fresh_since = HistoryIngestion::DAILY_FRESHNESS.ago.to_date

    stations_by_state = MonitoringLocation.active.group(:state_code).count
    location_state = MonitoringLocation.active.pluck(:id, :state_code).to_h
    selected = TimeSeries.selected.pluck(:id, :monitoring_location_id)
    selected.select! { |_series_id, location_id| location_state.key?(location_id) }

    has_year = DailyArchive.daily_coverage_series_ids(year_anchor)
    has_deep = DailyArchive.daily_coverage_series_ids(deep_anchor)
    # Denorm columns — avoid fleet plucks from continuous_observations.
    coverage_rows = TimeSeries.selected.pluck(
      :id, :continuous_newest_at, :has_continuous_anchor
    )
    has_continuous_tip = coverage_rows.each_with_object(Set.new) { |(id, newest, _), set|
      set << id if newest.present? && newest >= continuous_since
    }
    has_continuous_anchor = coverage_rows.each_with_object(Set.new) { |(id, _, anchored), set|
      set << id if anchored
    }
    # Must include R2 shard tips — after DAILY_ARCHIVE_PRUNE, Postgres daily is empty.
    has_daily_tip = DailyArchive.fresh_daily_tip_series_ids(daily_fresh_since)

    needing_history_by_state = {}
    needing_deep_by_state = {}
    missing_year_by_state = {}
    missing_continuous_tip_by_state = {}
    missing_continuous_anchor_by_state = {}
    missing_daily_tip_by_state = {}
    has_continuous_tip_by_state = {}
    has_continuous_anchor_by_state = {}
    has_year_by_state = {}
    has_deep_by_state = {}
    has_daily_tip_by_state = {}
    selected_by_state = {}

    selected.group_by(&:last).each do |location_id, rows|
      state = location_state[location_id]
      series_ids = rows.map(&:first)
      missing_year = series_ids.any? { |id| !has_year.include?(id) }
      missing_deep = series_ids.any? { |id| !has_deep.include?(id) }
      missing_cont_tip = series_ids.any? { |id| !has_continuous_tip.include?(id) }
      missing_cont_anchor = series_ids.any? { |id| !has_continuous_anchor.include?(id) }
      missing_tip = series_ids.any? { |id| !has_daily_tip.include?(id) }
      phase1 = missing_cont_tip || missing_cont_anchor || missing_year || missing_tip

      selected_by_state[state] = selected_by_state[state].to_i + 1
      has_continuous_tip_by_state[state] = has_continuous_tip_by_state[state].to_i + 1 unless missing_cont_tip
      has_continuous_anchor_by_state[state] = has_continuous_anchor_by_state[state].to_i + 1 unless missing_cont_anchor
      has_year_by_state[state] = has_year_by_state[state].to_i + 1 unless missing_year
      has_deep_by_state[state] = has_deep_by_state[state].to_i + 1 unless missing_deep
      has_daily_tip_by_state[state] = has_daily_tip_by_state[state].to_i + 1 unless missing_tip

      missing_year_by_state[state] = missing_year_by_state[state].to_i + 1 if missing_year
      missing_continuous_tip_by_state[state] = missing_continuous_tip_by_state[state].to_i + 1 if missing_cont_tip
      missing_continuous_anchor_by_state[state] = missing_continuous_anchor_by_state[state].to_i + 1 if missing_cont_anchor
      missing_daily_tip_by_state[state] = missing_daily_tip_by_state[state].to_i + 1 if missing_tip

      if phase1
        needing_history_by_state[state] = needing_history_by_state[state].to_i + 1
      elsif missing_deep
        needing_deep_by_state[state] = needing_deep_by_state[state].to_i + 1
      end
    end

    station_count = stations_by_state.values.sum
    stations_needing_history = needing_history_by_state.values.sum
    stations_needing_deep_history = needing_deep_by_state.values.sum

    {
      # Plain hashes only — Hash default procs cannot be Marshal'd into Rails.cache.
      stations_by_state: stations_by_state,
      needing_history_by_state: needing_history_by_state,
      needing_deep_by_state: needing_deep_by_state,
      missing_year_by_state: missing_year_by_state,
      station_count: station_count,
      stations_needing_history: stations_needing_history,
      stations_needing_deep_history: stations_needing_deep_history,
      stations_missing_year_history: missing_year_by_state.values.sum,
      stations_history_ready: [
        station_count - stations_needing_history - stations_needing_deep_history,
        0
      ].max,
      per_state: per_state_rows(
        stations_by_state: stations_by_state,
        selected_by_state: selected_by_state,
        needing_history_by_state: needing_history_by_state,
        needing_deep_by_state: needing_deep_by_state,
        missing_year_by_state: missing_year_by_state,
        missing_continuous_tip_by_state: missing_continuous_tip_by_state,
        missing_continuous_anchor_by_state: missing_continuous_anchor_by_state,
        missing_daily_tip_by_state: missing_daily_tip_by_state,
        has_continuous_tip_by_state: has_continuous_tip_by_state,
        has_continuous_anchor_by_state: has_continuous_anchor_by_state,
        has_year_by_state: has_year_by_state,
        has_deep_by_state: has_deep_by_state,
        has_daily_tip_by_state: has_daily_tip_by_state
      )
    }
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
      current: scope.where(latest_observed_at: 1.hour.ago..).count,
      h1_plus: scope.where(latest_observed_at: 6.hours.ago...1.hour.ago).count,
      h6_plus: scope.where(latest_observed_at: 24.hours.ago...6.hours.ago).count,
      h24_plus: scope.where(latest_observed_at: 72.hours.ago...24.hours.ago).count,
      h72_plus: scope.where(latest_observed_at: 7.days.ago...72.hours.ago).count,
      stale: scope.where("latest_observed_at IS NULL OR latest_observed_at < ?", now - 7.days).count
    }
  end

  def per_state_rows(
    stations_by_state:,
    selected_by_state:,
    needing_history_by_state:,
    needing_deep_by_state:,
    missing_year_by_state:,
    missing_continuous_tip_by_state:,
    missing_continuous_anchor_by_state:,
    missing_daily_tip_by_state:,
    has_continuous_tip_by_state:,
    has_continuous_anchor_by_state:,
    has_year_by_state:,
    has_deep_by_state:,
    has_daily_tip_by_state:
  )
    codes = (
      stations_by_state.keys +
      selected_by_state.keys +
      needing_history_by_state.keys +
      needing_deep_by_state.keys +
      missing_year_by_state.keys
    ).uniq.sort
    codes.map do |code|
      station_count = stations_by_state[code].to_i
      selected_count = selected_by_state[code].to_i
      needing_history = needing_history_by_state[code].to_i
      needing_deep = needing_deep_by_state[code].to_i
      missing_year = missing_year_by_state[code].to_i
      history_ready = [ station_count - needing_history - needing_deep, 0 ].max
      {
        state_code: code,
        state_name: state_name_for(code),
        station_count: station_count,
        selected_count: selected_count,
        # Inventory (not mutually exclusive) — how far selected series have filled.
        has_continuous_tip: has_continuous_tip_by_state[code].to_i,
        has_continuous_anchor: has_continuous_anchor_by_state[code].to_i,
        has_year_history: has_year_by_state[code].to_i,
        has_deep_history: has_deep_by_state[code].to_i,
        has_daily_tip: has_daily_tip_by_state[code].to_i,
        needing_history: needing_history,
        # Phase-1 reason counts (overlapping — a station can miss more than one).
        missing_continuous_tip: missing_continuous_tip_by_state[code].to_i,
        missing_continuous_anchor: missing_continuous_anchor_by_state[code].to_i,
        missing_year_history: missing_year,
        missing_daily_tip: missing_daily_tip_by_state[code].to_i,
        needing_deep_history: needing_deep,
        # Mutually exclusive with the two backlog columns.
        history_ready: history_ready
      }
    end
  end

  def state_name_for(code)
    Usgs::StateCodes.name_for(code)
  rescue ArgumentError, KeyError
    code.to_s.upcase
  end

  def count_prefixed_redis_keys(prefix)
    count = 0
    cursor = "0"
    iterations = 0
    self.class.send(:redis_with_rescue) do |r|
      loop do
        iterations += 1
        cursor, keys = r.scan(cursor, match: "#{prefix}*", count: 1_000)
        count += keys.size
        break if cursor.to_s == "0"
        break if iterations >= REDIS_SCAN_MAX_ITERATIONS
      end
      count
    end || 0
  end

  def sidekiq_stats
    require "sidekiq/api"
    stats = Sidekiq::Stats.new
    queues = Sidekiq::Queue.all.map { |q| [ q.name, q.size ] }.to_h
    workers_by_queue = Hash.new(0)
    Sidekiq::ProcessSet.new.each do |process|
      Array(process["queues"]).each { |queue| workers_by_queue[queue.to_s] += 1 }
    end
    {
      enqueued: stats.enqueued,
      retry_size: stats.retry_size,
      dead_size: stats.dead_size,
      processed: stats.processed,
      failed: stats.failed,
      queues: queues,
      workers_by_queue: workers_by_queue,
      iv_repair_queue_depth: queues["iv_repair"].to_i,
      iv_repair_workers: workers_by_queue["iv_repair"].to_i
    }
  rescue StandardError => e
    { error: e.message }
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
