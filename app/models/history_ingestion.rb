class HistoryIngestion
  include ActiveModel::Model

  attr_accessor :client, :monitoring_location, :range, :progress, :mode
  attr_reader :last_stats

  DEFAULT_RANGE = "1y"
  DEEP_RANGE = "3y"
  MODE_FULL = "full"
  # Tip / tip-adjacent hollow-middle repair on USGS_API_HISTORY_IVREPAIR_KEY.
  MODE_IV_REPAIR = "iv_repair"
  # Deeper interior scars across CONTINUOUS_RETENTION on USGS_API_HISTORY_IVREPAIR2_KEY.
  MODE_IV_REPAIR_SCAR = "iv_repair_scar"
  # Batch continuous upserts so tip/gap fills don't one-row round-trip Postgres.
  # Prefer continuous_upsert_batch — constant is the AppConfig default.
  CONTINUOUS_UPSERT_BATCH = 500
  # High-resolution continuous tip; 1y/3y charts use daily values from R2.
  # Prefer continuous_retention — constant is the AppConfig default.
  CONTINUOUS_RETENTION = 35.days
  DAILY_RETENTION = 3.years
  # Phase-1 window for cold/lazy backfill (DEFAULT_RANGE). Daily history lives in R2.
  DAILY_YEAR_WINDOW = 1.year
  # A selected series is considered year-loaded once it has a daily point this old.
  DAILY_HISTORY_ANCHOR = 11.months
  # Deep (3y) history is ready once a daily point reaches this age.
  DAILY_DEEP_HISTORY_ANCHOR = 35.months
  # Continuous is considered loaded once a point reaches this age (~retention slack).
  # Tip-only stations from LatestObservationSync must still pull the older IV window.
  CONTINUOUS_HISTORY_ANCHOR = 32.days
  # Legacy "tip looks fresh enough" gate for batch scopes that predate interior
  # gap repair. Prefer continuous_gap_threshold for tip→now coverage checks.
  CONTINUOUS_FRESHNESS = 7.days
  # Refresh daily tips when the newest local day is older than this.
  DAILY_FRESHNESS = 2.days
  # Overlap when extending from an existing tip so revised USGS points are picked up.
  CONTINUOUS_OVERLAP = 30.minutes
  # Consecutive IV spacing (or tip→now) above this is a hole we should re-fetch.
  # Tip sync is ~hourly, so keep this above 1h to avoid endless densify of healthy
  # tip spacing — overnight outages (many hours) still qualify.
  CONTINUOUS_GAP_THRESHOLD = 2.hours

  def self.continuous_retention
    AppConfig.integer(:continuous_retention_days).days
  end

  def self.continuous_gap_threshold
    AppConfig.integer(:continuous_gap_threshold_seconds).seconds
  end

  def self.continuous_freshness
    AppConfig.integer(:continuous_freshness_days).days
  end

  def self.continuous_upsert_batch
    AppConfig.integer(:continuous_upsert_batch)
  end

  def continuous_retention = self.class.continuous_retention
  def continuous_gap_threshold = self.class.continuous_gap_threshold
  def continuous_freshness = self.class.continuous_freshness
  def continuous_upsert_batch = self.class.continuous_upsert_batch

  def initialize(monitoring_location:, range: DEFAULT_RANGE, client: nil, progress: nil, mode: MODE_FULL)
    @monitoring_location = monitoring_location
    @range = range
    # Optional shared client for tests; production resolves a purpose-pinned
    # client per collection (continuous / daily / peaks / iv_repair).
    @client = client
    @clients = {}
    @progress = progress
    @mode = mode.presence || MODE_FULL
  end

  def tip_iv_repair?
    mode.to_s == MODE_IV_REPAIR
  end

  def iv_repair_scar?
    mode.to_s == MODE_IV_REPAIR_SCAR
  end

  # Either IV-repair lane (tip-adjacent or interior scar) — continuous-only ingest.
  def iv_repair?
    tip_iv_repair? || iv_repair_scar?
  end

  def perform
    # Root span: long ingest must not depend on an ambient ActiveJob/Rake parent
    # that may fail to export (Honeycomb "missing root span").
    Telemetry.in_root_span(
      "history.ingest",
      attributes: {
        "app.operation" => "history.ingest",
        "app.site_number" => monitoring_location.site_number,
        "app.usgs_monitoring_location_id" => monitoring_location.usgs_monitoring_location_id,
        "app.location_name" => monitoring_location.display_name,
        "app.state" => monitoring_location.state_code,
        "app.range" => range.to_s,
        "app.ingest_mode" => mode.to_s
      }
    ) do
      progress&.step("site=#{monitoring_location.site_number} range=#{range} mode=#{mode}")
      series_list = monitoring_location.time_series.selected.includes(:latest_observation).to_a
      progress&.step("selected_series=#{series_list.size}")
      clear_stale_usgs_daily_absent_flags!(series_list) unless iv_repair?

      active_series = series_list.select(&:eligible_for_recent_history_backfill?)
      if active_series.size < series_list.size
        skipped = series_list.size - active_series.size
        progress&.step("skipping_inactive_series=#{skipped} (tip older than #{continuous_retention.inspect})")
      end

      continuous_series = if tip_iv_repair?
        active_series.select { |s| self.class.series_needs_iv_repair?(s) }
      elsif iv_repair_scar?
        active_series.select { |s| self.class.series_needs_iv_scar_repair?(s) }
      elsif continuous_range?
        active_series.select { |s| needs_continuous?(s) }
      else
        []
      end
      daily_series = iv_repair? ? [] : (daily_range? ? active_series.select { |s| needs_daily?(s) } : [])
      peak_series = iv_repair? ? [] : active_series.select { |s| needs_peaks?(s) }

      if iv_repair?
        progress&.step(
          "#{mode} series=#{continuous_series.size}/#{active_series.size} " \
          "parameters=#{continuous_series.map(&:parameter_code).uniq.join(",")}"
        )
        Rails.logger.info(
          "HistoryIngestion #{mode} site=#{monitoring_location.site_number} " \
          "repair_series=#{continuous_series.size} active_series=#{active_series.size} " \
          "parameters=#{continuous_series.map(&:parameter_code).uniq.inspect}"
        )
      end

      @continuous_incomplete = false
      continuous_count = ingest_continuous_for(continuous_series)
      daily_count = ingest_daily_for(daily_series)
      peak_count = ingest_peaks_for(peak_series)
      observation_count = continuous_count + daily_count + peak_count
      finalize_iv_scar!(continuous_series) if iv_repair_scar?

      @last_stats = {
        continuous_observation_count: continuous_count,
        daily_observation_count: daily_count,
        peak_observation_count: peak_count,
        observation_count: observation_count,
        continuous_series_count: continuous_series.size,
        daily_series_count: daily_series.size,
        peak_series_count: peak_series.size,
        range_count: @last_continuous_range_count.to_i,
        continuous_incomplete: @continuous_incomplete
      }

      Telemetry.add_attributes(
        "app.series_count" => series_list.size,
        "app.batch_size" => continuous_series.size + daily_series.size + peak_series.size,
        "app.continuous_series_count" => continuous_series.size,
        "app.daily_series_count" => daily_series.size,
        "app.peak_series_count" => peak_series.size,
        "app.continuous_observation_count" => continuous_count,
        "app.daily_observation_count" => daily_count,
        "app.peak_observation_count" => peak_count,
        "app.observation_count" => observation_count,
        "app.range_count" => @last_continuous_range_count.to_i,
        "app.continuous_incomplete" => @continuous_incomplete
      )

      # History may write fresher continuous points while hourly tip sync lagged.
      # Advance LatestObservation + denormalized map columns so popups/cards match.
      advance_latest_tips!(series_list)
      DisplaySeriesSelection.denormalize!(monitoring_location)
      StationSnapshotCache.warm(monitoring_location)
      EdgeCacheInvalidation.after_station_history!(monitoring_location)
      progress&.finish("site=#{monitoring_location.site_number}")
      true
    end
  end


  private

  def client_for(purpose)
    return @client if @client

    resolved =
      if purpose == :continuous && iv_repair_scar?
        :iv_repair2
      elsif purpose == :continuous && tip_iv_repair?
        :iv_repair
      else
        purpose
      end
    @clients[resolved] ||= Usgs::Client.for_history(resolved)
  end

  def with_purpose_client(purpose)
    client_for(purpose)
  rescue Usgs::Client::RateLimitError => e
    progress&.step("#{purpose} skipped (#{e.message})")
    nil
  end

  def continuous_range?
    %w[24h 7d 30d 1y 3y].include?(range)
  end

  def daily_range?
    %w[1y 3y 30d].include?(range) || range == "por"
  end

  def needs_continuous?(series)
    return true unless series.has_continuous_anchor?

    newest = series.continuous_newest_at
    return true if newest.blank? || newest < continuous_gap_threshold.ago

    continuous_interior_gap_ranges(
      series,
      window_start: continuous_window_start,
      ends: Time.current.utc
    ).any?
  end

  def needs_daily?(series)
    # IV-only parameters (no USGS daily DV) are not fillable via the daily API.
    return false unless series.expects_daily_history?

    # Deep/year anchors live in R2 — don't re-pull USGS when coverage exists.
    return true unless series.has_daily_on_or_before?(daily_history_anchor)

    newest = series.newest_daily_on
    newest.blank? || newest < DAILY_FRESHNESS.ago.to_date
  end

  def continuous_history_anchor
    case range
    when "24h" then 20.hours.ago.utc
    when "7d" then 6.days.ago.utc
    when "30d" then 25.days.ago.utc
    else
      CONTINUOUS_HISTORY_ANCHOR.ago.utc
    end
  end

  def daily_history_anchor
    case range
    when "3y", "por" then DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    else DAILY_HISTORY_ANCHOR.ago.to_date
    end
  end

  def needs_peaks?(series)
    return false unless series.measurement_kind.in?(%w[water_level discharge])

    series.peak_observations.none?
  end

  def continuous_window_start
    case range
    when "24h" then 24.hours.ago.utc
    when "7d" then 7.days.ago.utc
    when "30d" then 30.days.ago.utc
    when "1y", "3y" then continuous_retention.ago.utc
    else
      continuous_retention.ago.utc
    end
  end

  def daily_window_start
    case range
    when "3y", "por" then DAILY_RETENTION.ago.to_date
    when "1y" then DAILY_YEAR_WINDOW.ago.to_date
    else
      30.days.ago.to_date
    end
  end

  def parameter_codes_param(series_list)
    series_list.map(&:parameter_code).uniq.join(",")
  end

  # USGS continuous rejects bare ISO-8601 durations (P7D/PT24H) despite docs;
  # use an explicit RFC3339 interval instead.
  #
  # Coverage model (not just oldest-hole + stale tip):
  # 1. empty → full window
  # 2. oldest > window_start → fill leading archive hole
  # 3. newest lagged past continuous_gap_threshold → extend tip→now
  # 4. interior consecutive gaps > threshold → re-fetch each hole
  #
  # Tip sync only upserts the latest IV point, so overnight misses leave a fresh
  # tip with a hollow middle — (4) is what repairs that.
  def continuous_datetime_ranges(series)
    window_start = continuous_window_start
    ends = Time.current.utc
    newest = series.continuous_newest_at&.utc
    ranges = []

    if newest.nil?
      return [ [ window_start, ends ] ]
    end

    # Leading hole: retention start → oldest local point (per-series MIN).
    # Tip-only archives (no ~32d anchor) still use this rather than tip→now.
    oldest = series.continuous_observations.minimum(:observed_at)&.utc
    if oldest && oldest > window_start
      ranges << [ window_start, oldest ] if window_start < oldest
    end

    if newest < continuous_gap_threshold.before(ends)
      tip_start = [ newest - CONTINUOUS_OVERLAP, window_start ].max
      ranges << [ tip_start, ends ] if tip_start < ends
    end

    ranges.concat(continuous_interior_gap_ranges(series, window_start: window_start, ends: ends))
    ranges
  end

  # [prev - overlap, next + overlap] for each consecutive pair spaced further
  # apart than continuous_gap_threshold inside the retention window.
  def continuous_interior_gap_ranges(series, window_start:, ends:)
    times = series.continuous_observations
      .where(observed_at: window_start..ends)
      .order(:observed_at)
      .pluck(:observed_at)
    return [] if times.size < 2

    threshold = continuous_gap_threshold
    overlap = CONTINUOUS_OVERLAP
    gaps = []
    times.each_cons(2) do |prev_at, next_at|
      next unless (next_at - prev_at) > threshold

      gap_start = [ prev_at - overlap, window_start ].max
      gap_end = [ next_at + overlap, ends ].min
      gaps << [ gap_start.utc, gap_end.utc ] if gap_start < gap_end
    end
    gaps
  end

  # Class helper for backfill eligibility / batch scopes.
  def self.series_has_continuous_coverage_gap?(series, window_start: continuous_retention.ago, ends: Time.current.utc)
    newest = series.continuous_newest_at
    return true if newest.blank?
    return true if newest < continuous_gap_threshold.before(ends)
    return true unless series.has_continuous_anchor?

    ingestion = new(monitoring_location: series.monitoring_location, range: DEFAULT_RANGE)
    ingestion.send(
      :continuous_interior_gap_ranges,
      series,
      window_start: window_start,
      ends: ends
    ).any?
  end

  # Anchored series with a stale tip or tip-vs-previous hollow middle. Matches
  # needing_iv_repair batch eligibility (not cold missing-anchor fills).
  def self.series_needs_iv_repair?(series, ends: Time.current.utc)
    return false unless series.has_continuous_anchor?

    newest = series.continuous_newest_at&.utc
    return true if newest.blank? || newest < continuous_gap_threshold.before(ends)

    previous = series.continuous_prev_at&.utc
    return false if previous.blank?

    (newest - previous) > continuous_gap_threshold
  end

  # Anchored series with a healthy tip adjacency but a deeper interior hole in
  # the retained IV window. Served by the scar lane (key2), not tip IV repair.
  # USGS-empty holes are parked after a completed scar fetch until the denorm
  # gap grows or the retry window elapses — otherwise the candidate count only
  # climbs (hourly tip sync raises max-gap; most interior outages are unfillable).
  def self.series_needs_iv_scar_repair?(series, ends: Time.current.utc)
    return false unless series.has_continuous_anchor?
    return false if series_needs_iv_repair?(series, ends: ends)

    max_gap = series.continuous_max_gap_seconds
    return false if max_gap.blank?
    return false if max_gap <= continuous_gap_threshold.to_i
    return false if series_iv_scar_recently_checked?(series)

    true
  end

  def self.series_iv_scar_recently_checked?(series)
    checked_at = series.iv_scar_checked_at
    return false if checked_at.blank?
    return false if checked_at < iv_scar_retry_after
    return false if series.continuous_max_gap_seconds.to_i > series.iv_scar_checked_max_gap_seconds.to_i

    true
  end

  def self.iv_scar_retry_hours
    hours = AppConfig.integer(:history_iv_scar_retry_hours)
    hours = 24 if hours <= 0
    hours
  end

  def self.iv_scar_retry_after
    iv_scar_retry_hours.hours.ago
  end

  # Selected series whose newest IV tip is fresh but the previous point is more
  # than threshold older — the tip-sync hollow-middle case (overnight miss, then
  # a new tip). Used by needing_iv_repair.
  #
  # Reads denorm continuous_newest_at / continuous_prev_at on time_series (no
  # fleet scan of continuous_observations). Deeper interior holes use
  # continuous_max_gap_seconds + the scar IV-repair lane.
  def self.time_series_ids_with_tip_sync_gaps(threshold: continuous_gap_threshold)
    threshold_seconds = threshold.to_i
    tip_since = threshold.ago
    Rails.logger.info(
      "HistoryIngestion tip_sync_gap_scan starting threshold_s=#{threshold_seconds}"
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ids = TimeSeries.selected
      .where.not(continuous_newest_at: nil)
      .where.not(continuous_prev_at: nil)
      .where("continuous_newest_at >= ?", tip_since)
      .where("continuous_newest_at - continuous_prev_at > INTERVAL '#{threshold_seconds} seconds'")
      .pluck(:id)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info(
      "HistoryIngestion tip_sync_gap_scan ids=#{ids.size} " \
      "threshold_s=#{threshold_seconds} elapsed_ms=#{elapsed_ms}"
    )
    ids
  end

  # Cover every series gap with as few location-level requests as possible.
  def coalesced_continuous_ranges(series_list)
    ranges = series_list.flat_map { |series| continuous_datetime_ranges(series) }
    return [] if ranges.empty?

    merged = []
    ranges.sort_by(&:first).each do |start_at, end_at|
      if merged.empty? || start_at > merged.last[1]
        merged << [ start_at, end_at ]
      else
        merged.last[1] = [ merged.last[1], end_at ].max
      end
    end
    merged
  end

  def daily_datetime_ranges(series)
    window_start = daily_window_start
    today = Date.current
    oldest = series.oldest_daily_on
    newest = series.newest_daily_on
    ranges = []

    if oldest.nil?
      ranges << [ window_start, today ]
    else
      if oldest > window_start
        gap_end = oldest - 1
        ranges << [ window_start, gap_end ] if window_start <= gap_end
      end

      if newest.nil? || newest < DAILY_FRESHNESS.ago.to_date
        tip_start = newest || window_start
        ranges << [ tip_start, today ] if tip_start <= today
      end
    end

    ranges
  end

  # Cover every series gap with as few location-level requests as possible.
  def coalesced_daily_ranges(series_list)
    ranges = series_list.flat_map { |series| daily_datetime_ranges(series) }
    return [] if ranges.empty?

    merged = []
    ranges.sort_by(&:first).each do |start_date, end_date|
      if merged.empty? || start_date > merged.last[1] + 1
        merged << [ start_date, end_date ]
      else
        merged.last[1] = [ merged.last[1], end_date ].max
      end
    end
    merged
  end

  def resolve_series(item, series_list)
    ts_id = item["time_series_id"].to_s.presence
    if ts_id
      match = series_list.find { |series| series.usgs_time_series_id == ts_id }
      return match if match
    end

    code = item["parameter_code"].to_s.presence
    if code
      match = series_list.find { |series| series.parameter_code == code }
      return match if match
    end

    # Single-series requests (or sparse USGS payloads) can omit identifiers.
    series_list.first if series_list.size == 1
  end

  def advance_latest_tips!(series_list)
    series_list.each do |series|
      tip_at = series.continuous_newest_at || series.continuous_observations.maximum(:observed_at)
      next if tip_at.blank?

      latest = series.latest_observation
      next if latest && latest.observed_at.to_i >= tip_at.to_i

      tip = series.continuous_observations.find_by(observed_at: tip_at)
      next unless tip
      next if temperature_outlier?(series, tip.value)

      LatestObservation.upsert(
        {
          time_series_id: series.id,
          observed_at: tip.observed_at,
          value: tip.value,
          unit_of_measure: series.unit_of_measure,
          approval_status: tip.approval_status,
          qualifier: tip.qualifier,
          synced_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: :time_series_id
      )
    end
  end

  # After a completed scar fetch, refresh the sliding-window max-gap denorm and
  # park USGS-empty holes so they leave the candidate set until retry / a worse gap.
  def finalize_iv_scar!(attempted_series)
    ids = monitoring_location.time_series.selected.pluck(:id)
    TimeSeries.refresh_continuous_coverage!(ids)
    if !@continuous_incomplete && attempted_series.any?
      TimeSeries.record_iv_scar_check!(attempted_series.map(&:id))
    end
    monitoring_location.time_series.reset
    attempted_series.each(&:reload)
  end

  def ingest_continuous_for(series_list)
    @last_continuous_range_count = 0
    if series_list.empty?
      progress&.step("continuous skipped (already covered)")
      Rails.logger.info(
        "HistoryIngestion continuous skipped site=#{monitoring_location.site_number} " \
        "mode=#{mode} reason=no_series_needing_continuous"
      ) if iv_repair?
      return 0
    end

    ranges = coalesced_continuous_ranges(series_list)
    @last_continuous_range_count = ranges.size
    if ranges.empty?
      progress&.step("continuous skipped (already covered)")
      Rails.logger.info(
        "HistoryIngestion continuous skipped site=#{monitoring_location.site_number} " \
        "mode=#{mode} reason=no_datetime_ranges series=#{series_list.size}"
      ) if iv_repair?
      return 0
    end

    codes = parameter_codes_param(series_list)
    Telemetry.in_span(
      "history.ingest.continuous",
      attributes: {
        "app.operation" => "history.ingest.continuous",
        "app.site_number" => monitoring_location.site_number,
        "app.state" => monitoring_location.state_code,
        "app.range" => range.to_s,
        "app.ingest_mode" => mode.to_s,
        "app.series_count" => series_list.size,
        "app.batch_size" => series_list.size,
        "app.range_count" => ranges.size,
        "app.parameter_code_count" => series_list.map(&:parameter_code).uniq.size
      }
    ) do
      client = with_purpose_client(:continuous)
      unless client
        @continuous_incomplete = true
        Rails.logger.warn(
          "HistoryIngestion continuous aborted site=#{monitoring_location.site_number} " \
          "mode=#{mode} reason=client_unavailable"
        )
        return 0
      end

      progress&.step(
        "continuous location batch parameters=#{codes} ranges=#{ranges.size} " \
        "circuit=#{client.circuit_key}"
      )
      range_summary = ranges.map { |starts, ends|
        hours = ((ends - starts) / 1.hour).round(1)
        "#{starts.iso8601}/#{ends.iso8601}(~#{hours}h)"
      }.join(" ")
      Rails.logger.info(
        "HistoryIngestion continuous fetch site=#{monitoring_location.site_number} " \
        "mode=#{mode} circuit=#{client.circuit_key} parameters=#{codes} " \
        "ranges=#{ranges.size} #{range_summary}"
      )
      count = 0
      buffer = []
      begin
        ranges.each_with_index do |(starts, ends), index|
          datetime = "#{starts.iso8601}/#{ends.iso8601}"
          range_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          before = count
          client.each_collection_item(
            "continuous",
            monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
            parameter_code: codes,
            datetime: datetime
          ) do |item|
            series = resolve_series(item, series_list)
            next unless series

            observed_at = Time.zone.parse(item["time"] || item["datetime"].to_s) rescue nil
            value = item["value"]
            next if observed_at.blank? || value.blank?
            next if temperature_outlier?(series, value)

            now = Time.current
            buffer << {
              time_series_id: series.id,
              observed_at: observed_at,
              value: value,
              approval_status: item["approval_status"],
              qualifier: item["qualifier"],
              created_at: now,
              updated_at: now
            }
            if buffer.size >= continuous_upsert_batch
              flush_continuous_buffer!(buffer)
            end
            count += 1
            progress&.increment
          end
          range_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - range_started) * 1000).round
          Rails.logger.info(
            "HistoryIngestion continuous range site=#{monitoring_location.site_number} " \
            "mode=#{mode} index=#{index + 1}/#{ranges.size} datetime=#{datetime} " \
            "features=#{count - before} elapsed_ms=#{range_ms}"
          )
        end
      rescue Usgs::Client::RateLimitError => e
        @continuous_incomplete = true
        progress&.step("continuous stopped (#{e.message})")
        Rails.logger.warn(
          "HistoryIngestion continuous rate-limited site=#{monitoring_location.site_number} " \
          "mode=#{mode} upserted_so_far=#{count} error=#{e.message}"
        )
      end
      flush_continuous_buffer!(buffer)
      Telemetry.add_attributes(
        "app.observation_count" => count,
        "app.circuit_key" => client.circuit_key
      )
      progress&.step("continuous upserted=#{count}")
      Rails.logger.info(
        "HistoryIngestion continuous done site=#{monitoring_location.site_number} " \
        "mode=#{mode} upserted=#{count} ranges=#{ranges.size} circuit=#{client.circuit_key}"
      )
      count
    end
  end

  def flush_continuous_buffer!(buffer)
    return if buffer.empty?

    # USGS continuous payloads (and overlap around tip/gap fetches) can repeat the
    # same (time_series_id, observed_at) in one batch. Postgres rejects
    # ON CONFLICT DO UPDATE when a constrained row is proposed twice (WATER-K).
    rows = dedupe_continuous_upsert_rows(buffer)
    series_ids = rows.map { |row| row[:time_series_id] }.uniq

    ContinuousObservation.upsert_all(
      rows,
      unique_by: %i[time_series_id observed_at],
      update_only: %i[value approval_status qualifier]
    )
    TimeSeries.refresh_continuous_coverage!(series_ids)
    buffer.clear
  end

  def dedupe_continuous_upsert_rows(rows)
    rows.each_with_object({}) do |row, uniq|
      key = [ row[:time_series_id], row[:observed_at].to_i ]
      uniq[key] = row
    end.values
  end

  def ingest_daily_for(series_list)
    if series_list.empty?
      progress&.step("daily skipped (already covered)")
      return 0
    end

    ranges = coalesced_daily_ranges(series_list)
    if ranges.empty?
      progress&.step("daily skipped (already covered)")
      return 0
    end

    codes = parameter_codes_param(series_list)
    Telemetry.in_span(
      "history.ingest.daily",
      attributes: {
        "app.operation" => "history.ingest.daily",
        "app.site_number" => monitoring_location.site_number,
        "app.state" => monitoring_location.state_code,
        "app.range" => range.to_s,
        "app.series_count" => series_list.size,
        "app.batch_size" => series_list.size,
        "app.range_count" => ranges.size,
        "app.parameter_code_count" => series_list.map(&:parameter_code).uniq.size
      }
    ) do
      client = with_purpose_client(:daily)
      return 0 unless client

      progress&.step(
        "daily location batch parameters=#{codes} ranges=#{ranges.size} " \
        "circuit=#{client.circuit_key}"
      )
      count = 0
      per_series_counts = Hash.new(0)
      archive_buffer = Hash.new { |h, k| h[k] = [] }
      rate_limited = false
      begin
        ranges.each do |start_date, end_date|
          client.each_collection_item(
            "daily",
            monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
            parameter_code: codes,
            datetime: "#{start_date.iso8601}/#{end_date.iso8601}"
          ) do |item|
            series = resolve_series(item, series_list)
            next unless series

            day = Date.parse(item["time"] || item["date"] || item["datetime"].to_s) rescue nil
            value = item["value"]
            next if day.blank? || value.blank?
            next if temperature_outlier?(series, value)

            point = {
              "d" => day.iso8601,
              "v" => value.to_f,
              "s" => DailyArchive::SOURCE_USGS,
              "a" => item["approval_status"],
              "qualifier" => item["qualifier"]
            }
            if DailyArchive.archive_writes_enabled?
              archive_buffer[series.id] << point
            else
              upsert_postgres_daily!(series, day, item)
            end
            count += 1
            per_series_counts[series.id] += 1
            progress&.increment
          end
        end
      rescue Usgs::Client::RateLimitError => e
        rate_limited = true
        progress&.step("daily stopped (#{e.message})")
      end
      flush_daily_archive!(archive_buffer)
      mark_usgs_daily_availability!(series_list, per_series_counts, rate_limited: rate_limited)

      breakdown = series_list.filter_map { |s|
        n = per_series_counts[s.id]
        "#{s.parameter_code}=#{n}" if n.positive? || s.usgs_daily_absent?
      }.join(",")
      progress&.step(
        "daily upserted=#{count}#{" by_parameter=#{breakdown}" if breakdown.present?}"
      )
      Telemetry.add_attributes(
        "app.observation_count" => count,
        "app.circuit_key" => client.circuit_key
      )
      count
    end
  end

  # Clear false "daily absent" marks on long-inactive series (empty recent-window
  # fetch is not proof USGS never publishes DV — POR may have ended years ago).
  def clear_stale_usgs_daily_absent_flags!(series_list)
    series_list.each do |series|
      next unless series.usgs_daily_absent?
      next if series.recent_continuous_evidence?

      series.update!(usgs_daily_absent: false)
      progress&.step(
        "cleared daily-absent parameter=#{series.parameter_code} " \
        "(no recent IV; not treating as IV-only)"
      )
    end
  end

  # When a successful daily request returns no DV for a series that still lacks
  # the year anchor *and* has recent continuous IV, USGS is not publishing DV for
  # that parameter (IV-only). Do not mark long-dead POR series from an empty
  # recent-window fetch (they may have DV outside the last 1y).
  def mark_usgs_daily_availability!(series_list, per_series_counts, rate_limited:)
    return if rate_limited

    series_list.each do |series|
      received = per_series_counts[series.id].to_i
      if received.positive?
        if series.usgs_daily_absent?
          series.update!(usgs_daily_absent: false)
          progress&.step("daily available again parameter=#{series.parameter_code}")
        end
        next
      end

      series.daily_archive_shards.reset
      series.association(:daily_observations).reset
      # Only treat as IV-only when there is no ~1y daily at all. An empty deep
      # (3y) gap fetch must not brand a series that already has year DV as absent.
      year_anchor = DAILY_HISTORY_ANCHOR.ago.to_date
      next if series.has_daily_on_or_before?(year_anchor)
      next if series.usgs_daily_absent?
      next unless series.recent_continuous_evidence?

      series.update!(usgs_daily_absent: true)
      progress&.step(
        "daily unavailable parameter=#{series.parameter_code} " \
        "(USGS returned no DV; shorter ranges use continuous)"
      )
    end
  end

  def upsert_postgres_daily!(series, day, item)
    DailyObservation.upsert(
      {
        time_series_id: series.id,
        observed_on: day,
        value: item["value"],
        approval_status: item["approval_status"],
        qualifier: item["qualifier"],
        created_at: Time.current,
        updated_at: Time.current
      },
      unique_by: %i[time_series_id observed_on]
    )
  end

  def flush_daily_archive!(archive_buffer)
    return if archive_buffer.blank?

    writer = DailyArchive::Writer.new
    archive_buffer.each do |time_series_id, points|
      writer.upsert(time_series_id: time_series_id, points: points)
    end
  rescue Cloudflare::R2Client::Error => e
    Rails.logger.warn("[HistoryIngestion] daily archive write failed; falling back to Postgres: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    archive_buffer.each do |time_series_id, points|
      series = series_list_by_id[time_series_id]
      next unless series

      points.each do |point|
        upsert_postgres_daily!(
          series,
          Date.parse(point["d"]),
          {
            "value" => point["v"],
            "approval_status" => point["a"],
            "qualifier" => point["qualifier"]
          }
        )
      end
    end
  end

  def series_list_by_id
    @series_list_by_id ||= monitoring_location.time_series.selected.index_by(&:id)
  end

  def ingest_peaks_for(series_list)
    if series_list.empty?
      progress&.step("peaks skipped (already covered)")
      return 0
    end

    codes = parameter_codes_param(series_list)
    Telemetry.in_span(
      "history.ingest.peaks",
      attributes: {
        "app.operation" => "history.ingest.peaks",
        "app.site_number" => monitoring_location.site_number,
        "app.state" => monitoring_location.state_code,
        "app.series_count" => series_list.size,
        "app.batch_size" => series_list.size,
        "app.parameter_code_count" => series_list.map(&:parameter_code).uniq.size
      }
    ) do
      client = with_purpose_client(:peaks)
      return 0 unless client

      progress&.step("peaks location batch parameters=#{codes} circuit=#{client.circuit_key}")
      count = 0
      begin
        client.each_collection_item(
          "peaks",
          monitoring_location_id: monitoring_location.usgs_monitoring_location_id,
          parameter_code: codes
        ) do |item|
          series = resolve_series(item, series_list)
          next unless series

          value = item["value"]
          observed_at = Time.zone.parse(item["time"] || item["datetime"].to_s) rescue nil
          next if value.blank?

          water_year = item["water_year"] || (observed_at && water_year_for(observed_at))
          next if water_year.blank?

          PeakObservation.upsert(
            {
              time_series_id: series.id,
              water_year: water_year.to_i,
              observed_at: observed_at,
              value: value,
              peak_kind: "high",
              approval_status: item["approval_status"],
              created_at: Time.current,
              updated_at: Time.current
            },
            unique_by: %i[time_series_id water_year peak_kind]
          )
          count += 1
          progress&.increment
        end
      rescue Usgs::Client::RateLimitError => e
        progress&.step("peaks stopped (#{e.message})")
      end
      Telemetry.add_attributes(
        "app.observation_count" => count,
        "app.circuit_key" => client.circuit_key
      )
      progress&.step("peaks upserted=#{count}")
      count
    end
  end

  def water_year_for(time)
    time.month >= 10 ? time.year + 1 : time.year
  end

  def temperature_outlier?(series, value)
    series.measurement_kind == "temperature" && !Usgs::ParameterCodes.plausible_temperature_c?(value)
  end
end
