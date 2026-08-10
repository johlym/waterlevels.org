# Read-only diagnostic report for a monitoring location: selected series,
# observation coverage, history anchors, and backfill lock/cooldown state.
# Used by /admin/stations/:site_number and `bin/rails usgs:inspect`.
class StationInspector
  CONTINUOUS_FRESHNESS = HistoryIngestion::CONTINUOUS_FRESHNESS
  CONTINUOUS_HISTORY_ANCHOR = HistoryIngestion::CONTINUOUS_HISTORY_ANCHOR
  DAILY_HISTORY_ANCHOR = HistoryIngestion::DAILY_HISTORY_ANCHOR
  DAILY_DEEP_HISTORY_ANCHOR = HistoryIngestion::DAILY_DEEP_HISTORY_ANCHOR
  DAILY_FRESHNESS = HistoryIngestion::DAILY_FRESHNESS

  def self.find(site_number_or_slug)
    raw = site_number_or_slug.to_s.strip
    return if raw.blank?

    site_number = raw.split("-", 2).first
    MonitoringLocation.find_by(site_number: site_number)
  end

  def self.report(location)
    new(location).report
  end

  def initialize(location)
    @location = location
  end

  def report
    series_reports = series_list.map { |series| series_report(series) }
    selected = series_reports.select { |row| row[:selected] }
    findings = build_findings(selected, series_reports)

    {
      location: location_summary,
      backfill: backfill_summary,
      history_gates: history_gates_summary(selected),
      series: series_reports,
      findings: findings,
      anchors: {
        continuous_freshness: CONTINUOUS_FRESHNESS.ago.utc,
        continuous_history_anchor: CONTINUOUS_HISTORY_ANCHOR.ago.utc,
        daily_history_anchor: DAILY_HISTORY_ANCHOR.ago.to_date,
        daily_deep_history_anchor: DAILY_DEEP_HISTORY_ANCHOR.ago.to_date,
        daily_freshness: DAILY_FRESHNESS.ago.to_date
      }
    }
  end

  def to_text
    r = report
    lines = []
    loc = r[:location]
    lines << "Station #{loc[:site_number]} — #{loc[:display_name]} (#{loc[:state_code].upcase})"
    lines << "URL path: /gauges/#{loc[:state_code]}/#{loc[:to_param]}"
    lines << "Active=#{loc[:active]} stale=#{loc[:stale]} kinds=#{loc[:measurement_kinds].join(',')}"
    lines << "Flags: water_level=#{loc[:has_water_level]} discharge=#{loc[:has_discharge]} temperature=#{loc[:has_temperature]}"
    lines << "Tip at=#{loc[:latest_observed_at] || '—'} stage=#{loc[:latest_water_level_value] || '—'} flow=#{loc[:latest_discharge_value] || '—'} temp_c=#{loc[:latest_temperature_c] || '—'}"
    lines << ""
    lines << "Backfill: needs=#{r[:backfill][:needs_history_backfill]} locked=#{r[:backfill][:locked]} cooldown=#{r[:backfill][:cooling_down]} sunday_pause=#{r[:backfill][:sunday_catalog_pause]}"
    lines << "Gates: missing_year=#{r[:history_gates][:missing_year_history]} missing_deep=#{r[:history_gates][:missing_deep_history]} has_deep=#{r[:history_gates][:has_deep_history]}"
    lines << ""
    lines << "Series (#{r[:series].size}):"
    r[:series].each do |s|
      sel = s[:selected] ? "selected" : "unselected"
      lines << "  [#{sel}] #{s[:measurement_kind]} #{s[:parameter_code]} #{s[:label]} id=#{s[:id]}"
      lines << "    continuous: count=#{s[:continuous][:count]} oldest=#{s[:continuous][:oldest_at] || '—'} newest=#{s[:continuous][:newest_at] || '—'}"
      lines << "    daily: pg=#{s[:daily][:postgres_count]} shards=#{s[:daily][:shard_count]} oldest=#{s[:daily][:oldest_on] || '—'} newest=#{s[:daily][:newest_on] || '—'}"
      lines << "    peaks=#{s[:peaks_count]} tip=#{s[:latest] ? "#{s[:latest][:value]} @ #{s[:latest][:observed_at]}" : '—'}"
      gaps = s[:gaps]
      next if gaps.empty?

      lines << "    gaps: #{gaps.join('; ')}"
    end
    lines << ""
    lines << "Findings:"
    if r[:findings].empty?
      lines << "  (none — selected series look complete against current anchors)"
    else
      r[:findings].each { |f| lines << "  - [#{f[:severity]}] #{f[:summary]}" }
    end
    lines.join("\n")
  end

  private

  attr_reader :location

  def series_list
    @series_list ||= location.time_series
      .includes(:latest_observation, :daily_archive_shards)
      .order(:measurement_kind, :parameter_code, :id)
      .to_a
  end

  def location_summary
    {
      id: location.id,
      site_number: location.site_number,
      display_name: location.display_name,
      name: location.name,
      state_code: location.state_code,
      county_name: location.county_name,
      to_param: location.to_param,
      active: location.active?,
      stale: location.stale?,
      has_water_level: location.has_water_level?,
      has_discharge: location.has_discharge?,
      has_temperature: location.has_temperature?,
      measurement_kinds: location.measurement_kinds,
      latest_observed_at: location.latest_observed_at,
      latest_water_level_value: location.latest_water_level_value,
      latest_water_level_parameter_code: location.latest_water_level_parameter_code,
      latest_discharge_value: location.latest_discharge_value,
      latest_temperature_c: location.latest_temperature_c,
      metadata_synced_at: location.metadata_synced_at,
      nwps_lid: location.nwps_lid,
      flood_category: location.flood_category
    }
  end

  def backfill_summary
    {
      needs_history_backfill: location.needs_history_backfill?,
      missing_year_history: location.missing_year_history?,
      missing_deep_history: location.missing_deep_history?,
      has_deep_history: location.has_deep_history?,
      locked: HistoryBackfillLock.locked?(location.id),
      cooling_down: HistoryBackfillLock.cooling_down?(location.id),
      sunday_catalog_pause: HistoryBackfillJob.paused_for_catalog_sync?,
      history_keys_exhausted: Usgs::HistoryKeyPool.exhausted?,
      db_read_only_circuit: DatabaseReadOnlyCircuit.open?,
      lock_ttl: HistoryBackfillLock::TTL,
      cooldown_ttl: HistoryBackfillLock::COOLDOWN_TTL
    }
  end

  def history_gates_summary(selected)
    {
      selected_series_count: selected.size,
      missing_year_history: location.missing_year_history?,
      missing_deep_history: location.missing_deep_history?,
      has_deep_history: location.has_deep_history?,
      blocking_year_series: selected.select { |s| s[:gaps].include?("missing_year_daily") }.map { |s| series_label(s) },
      blocking_deep_series: selected.select { |s| s[:gaps].include?("missing_deep_daily") }.map { |s| series_label(s) },
      blocking_continuous_tip: selected.select { |s| s[:gaps].include?("stale_or_missing_continuous_tip") }.map { |s| series_label(s) },
      blocking_continuous_anchor: selected.select { |s| s[:gaps].include?("missing_continuous_anchor") }.map { |s| series_label(s) },
      blocking_daily_tip: selected.select { |s| s[:gaps].include?("stale_or_missing_daily_tip") }.map { |s| series_label(s) }
    }
  end

  def series_report(series)
    continuous_oldest = series.continuous_observations.minimum(:observed_at)
    continuous_newest = series.continuous_observations.maximum(:observed_at)
    continuous_count = series.continuous_observations.count
    daily_pg_count = series.daily_observations.count
    shard_count = series.daily_archive_shards.size
    oldest_daily = series.oldest_daily_on
    newest_daily = series.newest_daily_on
    tip = series.latest_observation
    gaps = series_gaps(
      series,
      continuous_oldest: continuous_oldest,
      continuous_newest: continuous_newest,
      newest_daily: newest_daily
    )

    {
      id: series.id,
      usgs_time_series_id: series.usgs_time_series_id,
      measurement_kind: series.measurement_kind,
      parameter_code: series.parameter_code,
      label: Usgs::ParameterCodes.label_for(series.parameter_code, fallback: series.parameter_description),
      parameter_name: series.parameter_name,
      unit_of_measure: series.unit_of_measure,
      primary_series: series.primary_series?,
      selected: series.selected_for_display?,
      reporting: series.reporting?,
      begins_at: series.begins_at,
      ends_at: series.ends_at,
      metadata_synced_at: series.metadata_synced_at,
      continuous: {
        count: continuous_count,
        oldest_at: continuous_oldest,
        newest_at: continuous_newest
      },
      daily: {
        postgres_count: daily_pg_count,
        shard_count: shard_count,
        oldest_on: oldest_daily,
        newest_on: newest_daily,
        has_year_anchor: series.has_daily_on_or_before?(DAILY_HISTORY_ANCHOR.ago.to_date),
        has_deep_anchor: series.has_daily_on_or_before?(DAILY_DEEP_HISTORY_ANCHOR.ago.to_date)
      },
      peaks_count: series.peak_observations.count,
      latest: tip && {
        value: tip.value,
        unit_of_measure: tip.unit_of_measure,
        observed_at: tip.observed_at,
        approval_status: tip.approval_status,
        synced_at: tip.synced_at
      },
      gaps: gaps
    }
  end

  def series_gaps(series, continuous_oldest:, continuous_newest:, newest_daily:)
    return [] unless series.selected_for_display?

    gaps = []
    continuous_since = CONTINUOUS_FRESHNESS.ago
    continuous_anchor = CONTINUOUS_HISTORY_ANCHOR.ago
    daily_anchor = DAILY_HISTORY_ANCHOR.ago.to_date
    deep_anchor = DAILY_DEEP_HISTORY_ANCHOR.ago.to_date
    daily_fresh_since = DAILY_FRESHNESS.ago.to_date

    if continuous_newest.blank? || continuous_newest < continuous_since
      gaps << "stale_or_missing_continuous_tip"
    end
    if continuous_oldest.blank? || continuous_oldest > continuous_anchor
      gaps << "missing_continuous_anchor"
    end
    unless series.has_daily_on_or_before?(daily_anchor)
      gaps << "missing_year_daily"
    end
    if newest_daily.blank? || newest_daily < daily_fresh_since
      gaps << "stale_or_missing_daily_tip"
    end
    unless series.has_daily_on_or_before?(deep_anchor)
      gaps << "missing_deep_daily"
    end
    gaps
  end

  def build_findings(selected, all_series)
    findings = []
    bf = backfill_summary

    if selected.empty?
      findings << finding(
        :error,
        "no_selected_series",
        "No selected display series — gauge cards/charts have nothing to bind to."
      )
    end

    if bf[:missing_year_history]
      blockers = selected.select { |s| s[:gaps].include?("missing_year_daily") }
      labels = blockers.map { |s| series_label(s) }.join(", ")
      findings << finding(
        :warn,
        :year_history_callout,
        "Gauge page shows “Full-year history is still loading…” because at least one selected series lacks ~1y daily (anchor #{DAILY_HISTORY_ANCHOR.ago.to_date}): #{labels.presence || 'unknown'}."
      )
    end

    if bf[:needs_history_backfill] && bf[:cooling_down]
      findings << finding(
        :warn,
        :backfill_cooldown,
        "Station still needs history backfill but is on a #{HistoryBackfillLock::COOLDOWN_TTL.inspect} cooldown after a prior attempt — jobs may have run without clearing every selected-series gap."
      )
    elsif bf[:needs_history_backfill] && bf[:locked]
      findings << finding(
        :info,
        :backfill_locked,
        "A history backfill lock is held (TTL #{HistoryBackfillLock::TTL.inspect}) — a job is likely in progress."
      )
    elsif bf[:needs_history_backfill]
      findings << finding(
        :info,
        :backfill_eligible,
        "Station is eligible for HistoryBackfillJob (needs_history_backfill?=true)."
      )
    end

    if bf[:sunday_catalog_pause]
      findings << finding(
        :info,
        :sunday_pause,
        "HistoryBackfillJob is paused today for the Sunday catalog-sync window."
      )
    end

    if bf[:history_keys_exhausted]
      findings << finding(
        :error,
        :history_keys_exhausted,
        "USGS history key pool circuits are open — backfill enqueue/perform will skip."
      )
    end

    selected.each do |s|
      next unless s[:gaps].include?("stale_or_missing_continuous_tip")

      findings << finding(
        :warn,
        :partial_table_risk,
        "Selected #{series_label(s)} has a stale/missing continuous tip — hourly table rows can show Partial when this parameter is expected but absent for an hour."
      )
    end

    station_reporting = all_series.any? { |s| s[:reporting] }
    selected.select { |s| !s[:reporting] }.each do |s|
      next unless station_reporting

      findings << finding(
        :warn,
        :discontinued_still_selected,
        "Selected #{series_label(s)} tip is older than #{TimeSeries::REPORTING_TIP_WINDOW.inspect} while other series are still reporting — it should be dropped from display selection (Partial / year-history callout risk). Tip sync or `usgs:reselect` re-applies selection."
      )
    end

    unselected_with_data = all_series.reject { |s| s[:selected] }.select do |s|
      s[:continuous][:count].positive? || s[:daily][:postgres_count].positive? ||
        s[:daily][:shard_count].positive? || s[:latest].present?
    end
    unselected_with_data.each do |s|
      findings << finding(
        :info,
        :unselected_with_history,
        "Unselected #{series_label(s)} still has stored observations (continuous=#{s[:continuous][:count]}, daily_pg=#{s[:daily][:postgres_count]}, shards=#{s[:daily][:shard_count]}) — useful when a parameter used to appear on the gauge."
      )
    end

    %w[water_level discharge temperature].each do |kind|
      flag = location.public_send(:"has_#{kind}?")
      selected_kind = selected.any? { |s| s[:measurement_kind] == kind }
      catalog_kind = all_series.any? { |s| s[:measurement_kind] == kind }
      if flag && !selected_kind
        findings << finding(
          :warn,
          :flag_without_selection,
          "has_#{kind}=true but no selected #{kind} series — denormalized flags may be stale; run display reselect."
        )
      elsif !flag && catalog_kind
        findings << finding(
          :info,
          :catalog_kind_not_selected,
          "#{kind} series exist in the catalog but has_#{kind}=false (not selected for display)."
        )
      end
    end

    findings
  end

  def finding(severity, code, summary)
    { severity: severity, code: code.to_s, summary: summary }
  end

  def series_label(series_hash)
    "#{series_hash[:measurement_kind]}/#{series_hash[:parameter_code]}"
  end
end
