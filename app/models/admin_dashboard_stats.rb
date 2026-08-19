# Live ops snapshot for the password-gated /admin dashboard.
#
# Counter-backed (Postgres AdminCounter, written by jobs / AdminDashboardCountersJob):
#   - Job-finish / tip-refresh / IV candidate snapshots (record_job_finish!)
#   - Inventory aggregates (backfill coverage, measurement totals, stale/NWPS)
#   - Growth continuous 24h/7d window counts (COUNT on continuous_observations)
#
# Live on each section request (not Counters):
#   - Sidekiq health, USGS/DB circuit breakers
#   - Lock/cooldown Redis SCAN counts
#   - Tip-freshness histogram (active stations by latest_observed_at)
#   - "Last station updated" row
#
# The dashboard loads section snapshots via Turbo Frames so the shell can render
# before heavy work finishes; section payloads are still Rails.cache'd briefly.
require "set"

class AdminDashboardStats
  TIP_REFRESH_CACHE_KEY = "admin:last_tip_refresh".freeze
  JOB_CACHE_KEYS = {
    tip_refresh: TIP_REFRESH_CACHE_KEY,
    catalog_sync: "admin:last_catalog_sync",
    flood_sync: "admin:last_flood_sync",
    prune: "admin:last_prune",
    daily_archive_export: "admin:last_daily_archive_export",
    daily_archive_drain: "admin:last_daily_archive_drain",
    iv_repair_batch: "admin:last_iv_repair_batch",
    iv_repair: "admin:last_iv_repair",
    iv_repair_scar_batch: "admin:last_iv_repair_scar_batch",
    iv_repair_scar: "admin:last_iv_repair_scar"
  }.freeze
  # Last successful IV-repair eligibility scan size. Kept separate from
  # iv_repair_batch job-finish so skipped runs (circuit/queue/Sunday) do not
  # wipe the pipeline "Need IV repair" figure — and so /admin never re-runs
  # MonitoringLocation.iv_repair_candidate_ids (tip_sync_gap + continuous scans).
  IV_REPAIR_CANDIDATES_CACHE_KEY = "admin:iv_repair_candidates".freeze
  IV_SCAR_CANDIDATES_CACHE_KEY = "admin:iv_scar_candidates".freeze
  INVENTORY_KEY = "admin:inventory".freeze
  JOB_COUNTER_NAMES = (
    JOB_CACHE_KEYS.values + [ IV_REPAIR_CANDIDATES_CACHE_KEY, IV_SCAR_CANDIDATES_CACHE_KEY ]
  ).freeze
  APPROX_COUNT_THRESHOLD = SiteStats::APPROX_COUNT_THRESHOLD
  SECTIONS = %i[core pipeline growth jobs states health].freeze
  # Cheap sections first so the sequential frame loader warms UI quickly, then
  # core (which may refresh inventory Counters on miss), then remaining panels.
  SECTION_LOAD_ORDER = %i[jobs health core pipeline growth states].freeze
  # Bump when a section payload shape changes so deploys do not serve stale
  # hashes that crash the matching partial (Turbo then shows "Content missing").
  SECTION_CACHE_KEY_PREFIX = "admin_dashboard/section/v12".freeze
  SECTION_TTL = 2.minutes
  SECTION_RACE_TTL = 15.seconds
  REDIS_SCAN_MAX_ITERATIONS = 50
  # Default only — prefer AppConfig.integer(:admin_dashboard_statement_timeout_ms)
  # (ENV ADMIN_DASHBOARD_STATEMENT_TIMEOUT_MS or DB override).
  STATEMENT_TIMEOUT_MS = 12_000

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
      if name.to_sym == :iv_repair_scar_batch && extra.key?(:candidates)
        record_iv_scar_candidates!(extra[:candidates], scanned_at: finished_at)
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

    def record_iv_scar_candidates!(count, scanned_at: Time.current)
      write_job_payload(
        IV_SCAR_CANDIDATES_CACHE_KEY,
        {
          count: count.to_i,
          scanned_at: scanned_at.iso8601
        }
      )
    end

    def last_iv_repair_candidates_payload
      read_job_payload(IV_REPAIR_CANDIDATES_CACHE_KEY)
    end

    def last_iv_scar_candidates_payload
      read_job_payload(IV_SCAR_CANDIDATES_CACHE_KEY)
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

    def last_iv_scar_candidates
      payload = last_iv_scar_candidates_payload
      return payload[:count].to_i if payload&.key?(:count)

      batch = last_job(:iv_repair_scar_batch) || {}
      return batch[:candidates].to_i if batch.key?(:candidates)

      nil
    end

    def last_iv_scar_candidates_scanned_at
      payload = last_iv_scar_candidates_payload
      return parse_cached_time(payload[:scanned_at]) if payload&.key?(:scanned_at)

      batch = last_job(:iv_repair_scar_batch) || {}
      return parse_cached_time(batch[:finished_at]) if batch.key?(:candidates)

      nil
    end

    def last_tip_refresh
      last_job(:tip_refresh)
    end

    def last_job(name)
      read_job_payload(cache_key_for!(name))
    end

    def clear_tip_refresh!
      clear_jobs!
    end

    def clear_jobs!
      AdminCounter.clear!(*JOB_COUNTER_NAMES)
    end

    def parse_cached_time(value)
      return if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def bust_backfill_cache!
      AdminCounter.clear!(INVENTORY_KEY)
      SECTIONS.each { |name| Rails.cache.delete("#{SECTION_CACHE_KEY_PREFIX}/#{name}") }
    end

    def warm_backfill!
      refresh_inventory_counters!(source: "schedule")
    end

    def refresh_inventory_counters!(source: "schedule")
      new.refresh_inventory_counters!(source: source)
    end

    def schedule_inventory_refresh!
      unless AppConfig.boolean?(:admin_dashboard_counters_enabled)
        return
      end

      AdminDashboardCountersJob.perform_later
    rescue StandardError => e
      Rails.logger.warn("[AdminDashboardStats] schedule inventory refresh #{e.class}: #{e.message}")
      nil
    end

    def statement_timeout_ms
      AppConfig.integer(:admin_dashboard_statement_timeout_ms)
    rescue AppConfig::UnknownKeyError
      STATEMENT_TIMEOUT_MS
    end

    def with_statement_timeout(ms = nil)
      ms = statement_timeout_ms if ms.nil?
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

    def cache_key_for!(name)
      JOB_CACHE_KEYS.fetch(name.to_sym)
    end

    def write_job_payload(key, payload)
      computed_at = parse_cached_time(payload[:finished_at] || payload[:scanned_at]) || Time.current
      value =
        if payload.key?(:count)
          payload[:count].to_i
        elsif payload.key?(:stations_updated)
          payload[:stations_updated].to_i
        elsif payload.key?(:enqueued)
          payload[:enqueued].to_i
        elsif payload.key?(:candidates)
          payload[:candidates].to_i
        else
          0
        end

      AdminCounter.set!(
        key,
        value: value,
        source: "job",
        computed_at: computed_at,
        **payload
      )
    end

    def read_job_payload(key)
      AdminCounter.payload_for(key)
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

  def refresh_inventory_counters!(source: "schedule")
    backfill = compute_backfill_aggregates
    continuous_count = approximate_or_exact_count(ContinuousObservation)
    daily_count = approximate_or_exact_count(DailyObservation)
    peak_count = approximate_or_exact_count(PeakObservation)
    archive_daily_count = DailyArchive.cold_archive_point_count
    measurement_count = continuous_count + daily_count + peak_count + archive_daily_count
    window_counts = continuous_window_counts
    stale_station_count = [
      backfill[:station_count] - MonitoringLocation.active.not_stale.count,
      0
    ].max
    nwps_matched_count = MonitoringLocation.active.where(nwps_matched: true).count
    computed_at = Time.current

    AdminCounter.set!(
      INVENTORY_KEY,
      value: backfill[:station_count],
      source: source,
      computed_at: computed_at,
      backfill: backfill,
      continuous_observation_count: continuous_count,
      daily_observation_count: daily_count,
      peak_observation_count: peak_count,
      archive_daily_observation_count: archive_daily_count,
      daily_archive_shard_count: DailyArchive.shard_count,
      measurement_count: measurement_count,
      continuous_last_24h: window_counts[:continuous_last_24h],
      continuous_last_7d: window_counts[:continuous_last_7d],
      stale_station_count: stale_station_count,
      nwps_matched_count: nwps_matched_count
    )

    @inventory_payload = nil
    @backfill_aggregates = nil
    backfill.merge(inventory_computed_at: computed_at)
  end

  def core_section
    tip = tip_refresh_payload
    last_station = MonitoringLocation.order(updated_at: :desc).first
    inventory = inventory_payload
    backfill = backfill_aggregates

    {
      station_count: backfill[:station_count],
      stations_needing_history: backfill[:stations_needing_history],
      stations_missing_year_history: backfill[:stations_missing_year_history],
      measurement_count: inventory[:measurement_count],
      continuous_observation_count: inventory[:continuous_observation_count],
      daily_observation_count: inventory[:daily_observation_count],
      peak_observation_count: inventory[:peak_observation_count],
      archive_daily_observation_count: inventory[:archive_daily_observation_count],
      daily_archive_shard_count: inventory[:daily_archive_shard_count],
      inventory_computed_at: inventory[:computed_at],
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
      continuous_retention_days: AppConfig.integer(:continuous_retention_days)
    }
  end

  def pipeline_section
    backfill = backfill_aggregates
    inventory = inventory_payload
    site = SiteStats.snapshot

    {
      stations_needing_deep_history: backfill[:stations_needing_deep_history],
      stations_history_ready: backfill[:stations_history_ready],
      inventory_computed_at: inventory[:computed_at],
      # Last batch eligibility scan — never live needing_iv_repair / tip_sync_gap.
      stations_needing_iv_repair: self.class.last_iv_repair_candidates.to_i,
      iv_repair_candidates_scanned_at: self.class.last_iv_repair_candidates_scanned_at,
      stations_needing_iv_scar_repair: self.class.last_iv_scar_candidates.to_i,
      iv_scar_candidates_scanned_at: self.class.last_iv_scar_candidates_scanned_at,
      stale_station_count: inventory[:stale_station_count].to_i,
      flood_alert_count: site[:flood_alert_count],
      nwps_matched_count: inventory[:nwps_matched_count].to_i,
      updates_today: site[:updates_today],
      history_backfill_locks: count_prefixed_redis_keys(HistoryBackfillLock::KEY_PREFIX),
      history_backfill_cooldowns: count_prefixed_redis_keys(HistoryBackfillLock::COOLDOWN_PREFIX),
      iv_repair_locks: count_prefixed_redis_keys(IvRepairLock::KEY_PREFIX),
      iv_repair_cooldowns: count_prefixed_redis_keys(IvRepairLock::COOLDOWN_PREFIX)
    }
  end

  def growth_section
    # Read-only — never COUNT continuous_observations on the web request.
    # Those window aggregates live in inventory Counters (job / core miss).
    inventory = stored_inventory_payload
    last_24h = inventory[:continuous_last_24h].to_i
    recent_iv_series = TimeSeries.selected.where(continuous_newest_at: 24.hours.ago..).count

    {
      continuous_last_24h: last_24h,
      continuous_last_7d: inventory[:continuous_last_7d].to_i,
      inventory_computed_at: inventory[:computed_at],
      selected_series_count: TimeSeries.selected.count,
      recent_iv_series_count: recent_iv_series,
      implied_interval_minutes: implied_iv_interval_minutes(last_24h, recent_iv_series),
      tip_freshness: tip_freshness_histogram
    }
  end

  def jobs_section
    tip = tip_refresh_payload
    catalog = self.class.last_job(:catalog_sync) || {}
    flood = self.class.last_job(:flood_sync) || {}
    prune = self.class.last_job(:prune) || {}
    archive_export = self.class.last_job(:daily_archive_export) || {}
    archive_drain = self.class.last_job(:daily_archive_drain) || {}
    iv_repair_batch = self.class.last_job(:iv_repair_batch) || {}
    iv_repair = self.class.last_job(:iv_repair) || {}
    iv_scar_batch = self.class.last_job(:iv_repair_scar_batch) || {}
    iv_scar = self.class.last_job(:iv_repair_scar) || {}

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
      last_prune_vacuumed: prune[:vacuumed],
      last_daily_archive_export_at: parse_time(archive_export[:finished_at]),
      last_daily_archive_export_series: archive_export[:series],
      last_daily_archive_export_points: archive_export[:points],
      last_daily_archive_export_daily_deleted: archive_export[:daily_deleted].to_i,
      last_daily_archive_export_vacuumed: archive_export[:vacuumed],
      last_daily_archive_drain_at: parse_time(archive_drain[:finished_at]),
      last_daily_archive_drain_deleted: archive_drain[:daily_deleted].to_i,
      last_daily_archive_drain_blocked: archive_drain[:daily_blocked].to_i,
      last_daily_archive_drain_vacuumed: archive_drain[:vacuumed],
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
      last_iv_repair_elapsed_s: iv_repair[:elapsed_s],
      last_iv_scar_batch_at: parse_time(iv_scar_batch[:finished_at]),
      last_iv_scar_batch_enqueued: iv_scar_batch[:enqueued].to_i,
      last_iv_scar_batch_candidates: iv_scar_batch[:candidates].to_i,
      last_iv_scar_batch_skip_reason: iv_scar_batch[:skip_reason],
      last_iv_scar_batch_workers: iv_scar_batch[:workers],
      last_iv_scar_batch_queue_depth_after: iv_scar_batch[:queue_depth_after],
      last_iv_scar_at: parse_time(iv_scar[:finished_at]),
      last_iv_scar_site_number: iv_scar[:site_number],
      last_iv_scar_continuous_upserted: iv_scar[:continuous_upserted].to_i,
      last_iv_scar_still_needs: iv_scar[:still_needs],
      last_iv_scar_parked_unfillable: iv_scar[:parked_unfillable],
      last_iv_scar_recheck_at: parse_time(iv_scar[:usgs_iv_gap_recheck_at]),
      last_iv_scar_elapsed_s: iv_scar[:elapsed_s]
    }
  end

  def states_section
    inventory = inventory_payload
    {
      per_state: backfill_aggregates[:per_state],
      inventory_computed_at: inventory[:computed_at]
    }
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

  def inventory_payload
    @inventory_payload ||= begin
      stored = stored_inventory_payload
      if stored[:computed_at]
        stored
      else
        refresh_inventory_counters!(source: "schedule")
        stored_inventory_payload
      end
    end
  end

  # Last-known inventory row only. Growth uses this so a Counter miss cannot
  # trigger a 7-day continuous COUNT under the dashboard statement timeout.
  def stored_inventory_payload
    row = AdminCounter.fetch(INVENTORY_KEY)
    return {} unless row

    payload = AdminCounter.payload_for(INVENTORY_KEY) || {}
    payload.merge(computed_at: row.computed_at)
  end

  # One index range scan for both windows — 7d includes 24h.
  def continuous_window_counts
    since_24h = 24.hours.ago
    since_7d = 7.days.ago
    row = connection.select_one(
      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            SELECT
              COUNT(*) FILTER (WHERE observed_at >= ?) AS last_24h,
              COUNT(*) AS last_7d
            FROM continuous_observations
            WHERE observed_at >= ?
          SQL
          since_24h,
          since_7d
        ]
      )
    ) || {}

    {
      continuous_last_24h: row["last_24h"].to_i,
      continuous_last_7d: row["last_7d"].to_i
    }
  end

  def backfill_aggregates
    @backfill_aggregates ||= begin
      stored = inventory_payload[:backfill]
      if stored.is_a?(Hash) && stored[:station_count]
        stored
      else
        refresh_inventory_counters!(source: "schedule")
        inventory_payload[:backfill]
      end
    end
  end

  # One pass over selected series + small coverage sets — avoids nested
  # needing_history/deep ActiveRecord scopes that each seq-scan observations.
  def compute_backfill_aggregates
    year_anchor = HistoryIngestion::DAILY_HISTORY_ANCHOR.ago.to_date
    deep_anchor = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    continuous_since = HistoryIngestion.continuous_freshness.ago
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

  def implied_iv_interval_minutes(point_count, series_count)
    return if series_count <= 0 || point_count <= 0

    ((24.0 * 60) / (point_count.to_f / series_count)).round(1)
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
      iv_repair_workers: workers_by_queue["iv_repair"].to_i,
      iv_repair_scar_queue_depth: queues["iv_repair_scar"].to_i,
      iv_repair_scar_workers: workers_by_queue["iv_repair_scar"].to_i
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
