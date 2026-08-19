# Fleet-wide continuous IV storage check.
#
# /admin "continuous (~35d)" is a Postgres reltuples estimate of
# continuous_observations. USGS instantaneous values are typically 15-minute
# (96 points/day), not hourly — so one full 35-day series is ~3,360 rows.
# Mental math of `stations × 24h × 35d ≈ 15M` undercounts by ~4× and also
# treats each station as a single series. Gauge cards show at most 3 kinds,
# but selected_for_display can include multiple water-level parameter codes
# (gage height + an elevation datum) plus discharge and temperature.
#
# Cheap by default (time_series + pg_class + observed_at index bounds).
# Exact COUNT(*) is opt-in because the table is tens of millions of rows.
#
# Console:
#   puts ContinuousInventory.report
#   ContinuousInventory.snapshot
#   ContinuousInventory.snapshot(exact: true, sample: 80)
#
# Rake:
#   bin/rails usgs:continuous_inventory
#   EXACT=1 SAMPLE=80 bin/rails usgs:continuous_inventory
class ContinuousInventory
  POINTS_PER_DAY_HOURLY = 24
  POINTS_PER_DAY_15MIN = 96
  APPROX_COUNT_THRESHOLD = SiteStats::APPROX_COUNT_THRESHOLD
  DEFAULT_SAMPLE = 80
  HEALTHY_15MIN_RATIO = (0.35..1.25)
  SAMPLED_15MIN_SECONDS = (4.minutes.to_i..20.minutes.to_i)

  class << self
    def snapshot(exact: false, sample: DEFAULT_SAMPLE, as_of: Time.current)
      new(exact: exact, sample: sample, as_of: as_of).snapshot
    end

    def report(exact: false, sample: DEFAULT_SAMPLE, as_of: Time.current)
      new(exact: exact, sample: sample, as_of: as_of).to_text
    end
  end

  def initialize(exact: false, sample: DEFAULT_SAMPLE, as_of: Time.current)
    @exact = exact
    @sample = sample.to_i
    @sample = DEFAULT_SAMPLE if @sample <= 0
    @as_of = as_of
  end

  def snapshot
    @snapshot ||= build_snapshot
  end

  def to_text
    s = snapshot
    lines = []
    lines << "Continuous IV inventory  as_of=#{s[:as_of].utc.iso8601}"
    lines << "Retention: #{s[:retention_days]} days"
    lines << ""
    lines << "Postgres"
    lines << "  reltuples (dashboard): #{delim(s[:reltuples])}"
    lines << "  n_live_tup: #{delim(s[:n_live_tup])}"
    lines << "  n_dead_tup: #{delim(s[:n_dead_tup])}"
    lines << "  last_analyze: #{s[:last_analyze] || '—'}"
    lines << "  last_vacuum: #{s[:last_vacuum] || '—'}"
    lines << "  row_count used: #{delim(s[:row_count])}#{s[:exact] ? ' (exact COUNT)' : ' (estimate unless table is small)'}"
    lines << "  oldest: #{s[:oldest_at]&.utc&.iso8601 || '—'}"
    lines << "  newest: #{s[:newest_at]&.utc&.iso8601 || '—'}"
    lines << "  older than retention: #{delim(s[:beyond_retention_count])}"
    lines << ""
    lines << "Series"
    lines << "  active stations: #{delim(s[:station_count])}"
    lines << "  selected series: #{delim(s[:selected_series_count])}"
    lines << "  selected with IV denorm: #{delim(s[:selected_series_with_continuous_count])}"
    lines << "  unselected with IV denorm: #{delim(s[:unselected_series_with_continuous_count])}"
    lines << "  by kind: #{format_counts(s[:selected_series_by_kind])}"
    lines << "  per station: #{format_histogram(s[:selected_series_per_station])}"
    lines << "  water_level codes: #{format_counts(s[:water_level_parameter_counts])}"
    lines << ""
    lines << "Envelopes (full #{s[:retention_days]}d, no gaps)"
    lines << "  hourly × stations × 1 series: #{delim(s[:expected_hourly_one_series])}"
    lines << "  hourly × selected-with-IV: #{delim(s[:expected_hourly_full])}"
    lines << "  15-min × selected-with-IV: #{delim(s[:expected_15min_full])}"
    lines << "  row_count / 15-min envelope: #{ratio_text(s[:ratio_to_15min_full])}"
    lines << "  implied mean interval: #{format_seconds(s[:implied_interval_seconds])}"
    lines << ""
    cadence = s[:sampled_cadence]
    lines << "Sampled cadence (#{cadence[:sample_size]} series)"
    if cadence[:sample_size].positive?
      lines << "  median avg interval: #{format_seconds(cadence[:median_interval_seconds])}"
      lines << "  p10/p90: #{format_seconds(cadence[:p10_interval_seconds])} / #{format_seconds(cadence[:p90_interval_seconds])}"
      lines << "  median points/series: #{delim(cadence[:median_point_count])}"
    else
      lines << "  (no selected series with continuous points)"
    end
    lines << ""
    lines << "Verdict"
    s[:verdicts].each { |msg| lines << "  - #{msg}" }
    lines << ""
    lines << "Console: puts ContinuousInventory.report"
    lines << "Exact COUNT (slow on prod): ContinuousInventory.snapshot(exact: true)"
    lines.join("\n")
  end

  private

  def build_snapshot
    retention = HistoryIngestion.continuous_retention
    cutoff = retention.before(@as_of)
    stats = table_stats
    series = series_stats
    iv_series = series[:selected_series_with_continuous_count]
    days = (retention / 1.day).to_i
    expected_hourly_one = series[:station_count] * POINTS_PER_DAY_HOURLY * days
    expected_hourly_full = iv_series * POINTS_PER_DAY_HOURLY * days
    expected_15min_full = iv_series * POINTS_PER_DAY_15MIN * days
    row_count = resolve_row_count(stats[:reltuples])
    ratio = expected_15min_full.positive? ? (row_count.to_f / expected_15min_full) : nil
    span_seconds = span_seconds_for(stats[:oldest_at], stats[:newest_at], retention)
    points_per_series = iv_series.positive? ? (row_count.to_f / iv_series) : nil
    implied_interval = if points_per_series && points_per_series > 1 && span_seconds.positive?
      span_seconds / (points_per_series - 1)
    end
    cadence = sample_cadence(series[:sample_ids])
    stale_count = beyond_retention_count(cutoff)

    {
      as_of: @as_of,
      exact: @exact,
      retention_days: days,
      reltuples: stats[:reltuples],
      n_live_tup: stats[:n_live_tup],
      n_dead_tup: stats[:n_dead_tup],
      last_analyze: stats[:last_analyze],
      last_vacuum: stats[:last_vacuum],
      row_count: row_count,
      oldest_at: stats[:oldest_at],
      newest_at: stats[:newest_at],
      beyond_retention_count: stale_count,
      station_count: series[:station_count],
      selected_series_count: series[:selected_series_count],
      selected_series_with_continuous_count: iv_series,
      unselected_series_with_continuous_count: series[:unselected_series_with_continuous_count],
      selected_series_by_kind: series[:selected_series_by_kind],
      selected_series_per_station: series[:selected_series_per_station],
      water_level_parameter_counts: series[:water_level_parameter_counts],
      expected_hourly_one_series: expected_hourly_one,
      expected_hourly_full: expected_hourly_full,
      expected_15min_full: expected_15min_full,
      ratio_to_15min_full: ratio,
      implied_interval_seconds: implied_interval,
      sampled_cadence: cadence,
      verdicts: build_verdicts(
        ratio: ratio,
        beyond_retention: stale_count,
        unselected: series[:unselected_series_with_continuous_count],
        cadence: cadence,
        dead_tuples: stats[:n_dead_tup],
        live_tuples: stats[:n_live_tup]
      )
    }
  end

  def table_stats
    row = connection.select_one(<<~SQL.squish)
      SELECT c.reltuples::bigint AS reltuples,
             s.n_live_tup::bigint AS n_live_tup,
             s.n_dead_tup::bigint AS n_dead_tup,
             COALESCE(s.last_analyze, s.last_autoanalyze) AS last_analyze,
             COALESCE(s.last_vacuum, s.last_autovacuum) AS last_vacuum
      FROM pg_class c
      JOIN pg_stat_user_tables s ON s.relid = c.oid
      WHERE c.oid = #{connection.quote(ContinuousObservation.table_name)}::regclass
    SQL
    {
      reltuples: row&.fetch("reltuples", 0).to_i,
      n_live_tup: row&.fetch("n_live_tup", 0).to_i,
      n_dead_tup: row&.fetch("n_dead_tup", 0).to_i,
      last_analyze: row&.fetch("last_analyze", nil),
      last_vacuum: row&.fetch("last_vacuum", nil),
      oldest_at: ContinuousObservation.minimum(:observed_at),
      newest_at: ContinuousObservation.maximum(:observed_at)
    }
  end

  def series_stats
    selected = TimeSeries.selected
    selected_ids = selected.where.not(continuous_newest_at: nil).order(:id).pluck(:id)
    per_station = selected.group(:monitoring_location_id).count.values.tally
    histogram = { "1" => 0, "2" => 0, "3" => 0, "4+" => 0 }
    per_station.each do |n, stations|
      key = n >= 4 ? "4+" : n.to_s
      histogram[key] += stations
    end

    {
      station_count: MonitoringLocation.active.count,
      selected_series_count: selected.count,
      selected_series_with_continuous_count: selected_ids.size,
      unselected_series_with_continuous_count: TimeSeries.where(selected_for_display: false)
        .where.not(continuous_newest_at: nil).count,
      selected_series_by_kind: selected.group(:measurement_kind).count,
      selected_series_per_station: histogram,
      water_level_parameter_counts: selected.where(measurement_kind: "water_level")
        .group(:parameter_code).count,
      sample_ids: spread_sample(selected_ids)
    }
  end

  def resolve_row_count(reltuples)
    return ContinuousObservation.count if @exact || reltuples < APPROX_COUNT_THRESHOLD

    reltuples
  end

  def beyond_retention_count(cutoff)
    ContinuousObservation.where("observed_at < ?", cutoff).count
  end

  def span_seconds_for(oldest_at, newest_at, retention)
    return retention.to_i if oldest_at.blank? || newest_at.blank?

    [ newest_at - oldest_at, 1 ].max
  end

  def spread_sample(ids)
    return ids if ids.size <= @sample
    return [] if ids.empty?

    step = (ids.size.to_f / @sample).ceil
    ids.each_slice(step).map(&:first).first(@sample)
  end

  def sample_cadence(ids)
    empty = {
      sample_size: 0,
      median_interval_seconds: nil,
      p10_interval_seconds: nil,
      p90_interval_seconds: nil,
      median_point_count: nil
    }
    return empty if ids.blank?

    sql = ActiveRecord::Base.sanitize_sql_array(
      [
        <<~SQL.squish,
          SELECT COUNT(*)::bigint AS point_count,
                 EXTRACT(EPOCH FROM (MAX(observed_at) - MIN(observed_at)))
                   / NULLIF(COUNT(*) - 1, 0) AS avg_interval_seconds
          FROM continuous_observations
          WHERE time_series_id IN (?)
          GROUP BY time_series_id
        SQL
        ids
      ]
    )
    rows = connection.select_all(sql)
    intervals = rows.filter_map { |row| row["avg_interval_seconds"]&.to_f }
    points = rows.map { |row| row["point_count"].to_i }
    {
      sample_size: rows.size,
      median_interval_seconds: percentile(intervals, 0.5),
      p10_interval_seconds: percentile(intervals, 0.1),
      p90_interval_seconds: percentile(intervals, 0.9),
      median_point_count: percentile(points.map(&:to_f), 0.5)&.round
    }
  end

  def build_verdicts(ratio:, beyond_retention:, unselected:, cadence:, dead_tuples:, live_tuples:)
    messages = []
    if ratio && HEALTHY_15MIN_RATIO.cover?(ratio)
      messages << "row count sits in the 15-minute IV envelope — hourly × stations (~15M) undercounts by ~4×"
    elsif ratio && ratio > HEALTHY_15MIN_RATIO.end
      messages << "above a full 15-minute envelope — check 5-min sites, unselected leftovers, prune lag, or stale reltuples"
    elsif ratio && ratio < HEALTHY_15MIN_RATIO.begin
      messages << "below a full 15-minute envelope — gaps, hourly sites, or incomplete backfill (not extra rows)"
    else
      messages << "not enough selected IV series to compare against a 15-minute envelope"
    end

    median = cadence[:median_interval_seconds]
    if median && SAMPLED_15MIN_SECONDS.cover?(median.round)
      messages << "sampled series median spacing matches USGS 15-minute IV"
    elsif median && median >= 45.minutes.to_i
      messages << "sampled series look hourly or sparser — 65M would then be too high"
    elsif median && median <= 3.minutes.to_i
      messages << "sampled series look denser than 15-minute — finer USGS IV would explain extra rows"
    end

    if unselected.positive?
      messages << "#{delim(unselected)} unselected series still have IV denorm — leftover history, not extra cadence"
    end
    if beyond_retention.positive?
      messages << "#{delim(beyond_retention)} rows older than retention — prune lag"
    end
    if live_tuples.positive? && dead_tuples > live_tuples * 0.25
      messages << "dead tuples are high relative to live rows — reltuples may lag until VACUUM ANALYZE"
    end

    messages
  end

  def percentile(values, fraction)
    return if values.blank?

    sorted = values.sort
    index = ((sorted.size - 1) * fraction).round
    sorted[index]
  end

  def delim(value)
    value.to_i.to_fs(:delimited)
  end

  def format_counts(hash)
    return "—" if hash.blank?

    hash.sort_by { |key, _| key.to_s }.map { |key, count| "#{key}=#{delim(count)}" }.join(" ")
  end

  def format_histogram(hash)
    %w[1 2 3 4+].map { |key| "#{key}=#{delim(hash[key].to_i)}" }.join("  ")
  end

  def format_seconds(seconds)
    return "—" if seconds.blank?

    minutes = seconds.to_f / 60.0
    return "#{minutes.round(1)} min" if minutes < 90

    "#{(minutes / 60.0).round(1)} h"
  end

  def ratio_text(ratio)
    return "—" if ratio.blank?

    format("%.2f", ratio)
  end

  def connection
    ActiveRecord::Base.connection
  end
end
