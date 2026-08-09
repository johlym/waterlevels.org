class HistoryIngestion
  include ActiveModel::Model

  attr_accessor :client, :monitoring_location, :range, :progress

  DEFAULT_RANGE = "1y"
  DEEP_RANGE = "3y"
  # Batch continuous upserts so tip/gap fills don't one-row round-trip Postgres.
  CONTINUOUS_UPSERT_BATCH = 500
  # High-resolution continuous tip; 1y/3y charts use daily values from R2.
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
  # Refresh continuous tips when the newest local point is older than this.
  CONTINUOUS_FRESHNESS = 7.days
  # Refresh daily tips when the newest local day is older than this.
  DAILY_FRESHNESS = 2.days
  # Overlap when extending from an existing tip so revised USGS points are picked up.
  CONTINUOUS_OVERLAP = 30.minutes

  def initialize(monitoring_location:, range: DEFAULT_RANGE, client: nil, progress: nil)
    @monitoring_location = monitoring_location
    @range = range
    @client = client || Usgs::Client.for_history
    @progress = progress
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
        "app.circuit_key" => client.circuit_key
      }
    ) do
      progress&.step("site=#{monitoring_location.site_number} range=#{range}")
      series_list = monitoring_location.time_series.selected.to_a
      progress&.step("selected_series=#{series_list.size}")

      continuous_series = continuous_range? ? series_list.select { |s| needs_continuous?(s) } : []
      daily_series = daily_range? ? series_list.select { |s| needs_daily?(s) } : []
      peak_series = series_list.select { |s| needs_peaks?(s) }

      continuous_count = ingest_continuous_for(continuous_series)
      daily_count = ingest_daily_for(daily_series)
      peak_count = ingest_peaks_for(peak_series)
      observation_count = continuous_count + daily_count + peak_count

      Telemetry.add_attributes(
        "app.series_count" => series_list.size,
        "app.batch_size" => continuous_series.size + daily_series.size + peak_series.size,
        "app.continuous_series_count" => continuous_series.size,
        "app.daily_series_count" => daily_series.size,
        "app.peak_series_count" => peak_series.size,
        "app.continuous_observation_count" => continuous_count,
        "app.daily_observation_count" => daily_count,
        "app.peak_observation_count" => peak_count,
        "app.observation_count" => observation_count
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

  def continuous_range?
    %w[24h 7d 30d 1y 3y].include?(range)
  end

  def daily_range?
    %w[1y 3y 30d].include?(range) || range == "por"
  end

  def needs_continuous?(series)
    return true if series.continuous_observations.where(observed_at: ..continuous_history_anchor).none?

    newest = series.continuous_observations.maximum(:observed_at)
    newest.blank? || newest < CONTINUOUS_FRESHNESS.ago
  end

  def needs_daily?(series)
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
    when "1y", "3y" then CONTINUOUS_RETENTION.ago.utc
    else
      CONTINUOUS_RETENTION.ago.utc
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
  # Gap-aware like daily: fill the older archive hole, and separately refresh a
  # stale tip. Tip-only stations (LatestObservationSync / catalog) must still
  # pull window_start → oldest so 30d/90d charts are complete.
  def continuous_datetime_ranges(series)
    window_start = continuous_window_start
    ends = Time.current.utc
    oldest = series.continuous_observations.minimum(:observed_at)&.utc
    newest = series.continuous_observations.maximum(:observed_at)&.utc
    ranges = []

    if oldest.nil?
      ranges << [ window_start, ends ]
    else
      if oldest > window_start
        ranges << [ window_start, oldest ] if window_start < oldest
      end

      if newest.nil? || newest < CONTINUOUS_FRESHNESS.ago
        tip_start = newest ? (newest - CONTINUOUS_OVERLAP) : window_start
        tip_start = [ tip_start, window_start ].max
        ranges << [ tip_start, ends ] if tip_start < ends
      end
    end

    ranges
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
      tip_at = series.continuous_observations.maximum(:observed_at)
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

  def ingest_continuous_for(series_list)
    if series_list.empty?
      progress&.step("continuous skipped (already covered)")
      return 0
    end

    ranges = coalesced_continuous_ranges(series_list)
    if ranges.empty?
      progress&.step("continuous skipped (already covered)")
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
        "app.series_count" => series_list.size,
        "app.batch_size" => series_list.size,
        "app.range_count" => ranges.size,
        "app.parameter_code_count" => series_list.map(&:parameter_code).uniq.size
      }
    ) do
      progress&.step("continuous location batch parameters=#{codes} ranges=#{ranges.size}")
      count = 0
      buffer = []
      ranges.each do |starts, ends|
        datetime = "#{starts.iso8601}/#{ends.iso8601}"
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
          if buffer.size >= CONTINUOUS_UPSERT_BATCH
            flush_continuous_buffer!(buffer)
          end
          count += 1
          progress&.increment
        end
      end
      flush_continuous_buffer!(buffer)
      Telemetry.add_attributes("app.observation_count" => count)
      progress&.step("continuous upserted=#{count}")
      count
    end
  end

  def flush_continuous_buffer!(buffer)
    return if buffer.empty?

    ContinuousObservation.upsert_all(
      buffer,
      unique_by: %i[time_series_id observed_at],
      update_only: %i[value approval_status qualifier]
    )
    buffer.clear
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
      progress&.step("daily location batch parameters=#{codes} ranges=#{ranges.size}")
      count = 0
      archive_buffer = Hash.new { |h, k| h[k] = [] }
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
          progress&.increment
        end
      end
      flush_daily_archive!(archive_buffer)
      Telemetry.add_attributes("app.observation_count" => count)
      progress&.step("daily upserted=#{count}")
      count
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
      progress&.step("peaks location batch parameters=#{codes}")
      count = 0
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
      Telemetry.add_attributes("app.observation_count" => count)
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
