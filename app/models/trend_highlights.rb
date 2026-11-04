# National lists for the homepage, warmed after tip sync.
#
# Movers use the preferred stage series and the selected discharge series.
# The tip must be younger than TIP_MAX_AGE. The prior reading is the continuous
# point closest to PRIOR_HOURS before that tip, and it has to fall in the band
# PRIOR_BAND on either side of that mark (18 to 30 hours before the tip).
# Stage is ranked by the rise in feet. Discharge is ranked by percent, and
# only when the prior reading is at least DISCHARGE_PRIOR_FLOOR.
#
# A new high is a latest stage or discharge strictly above every stored annual
# peak, with peaks from at least RECORD_MIN_WATER_YEARS distinct water years.
# Tips older than MonitoringLocation::STALE_AFTER are left off that list.
# Empty peak history is not a record.
class TrendHighlights
  CACHE_KEY = "trend_highlights/v1"
  TTL = 2.hours
  LIST_LIMIT = 8
  RECORD_MIN_WATER_YEARS = 10
  DISCHARGE_PRIOR_FLOOR = 10
  PRIOR_HOURS = 24
  PRIOR_BAND = 6.hours
  TIP_MAX_AGE = 6.hours
  PRIOR_CHUNK = 1_000

  class << self
    def read
      raw = Rails.cache.read(CACHE_KEY)
      return unless raw.is_a?(Hash)

      normalize(raw)
    end

    def fetch
      cached = read
      return cached if fresh?(cached)

      warm
    end

    def warm
      payload = normalize(compute)
      Rails.cache.write(CACHE_KEY, payload, expires_in: TTL)
      payload
    end

    def clear!
      Rails.cache.delete(CACHE_KEY)
    end

    # Cache read only. Gauge pages must not rebuild the national lists.
    def mention_for(site_number)
      payload = read
      return if payload.blank?

      site = site_number.to_s
      mover = listed?(payload[:stage_movers], site) || listed?(payload[:discharge_movers], site)
      record = listed?(payload[:records], site)
      return unless mover || record

      if mover && record
        { text: "Featured in today's rising stations and new highs", anchor: "home-trends" }
      elsif record
        { text: "Featured in today's new highs", anchor: "new-highs" }
      else
        { text: "Featured in today's rising stations", anchor: "rising-fastest" }
      end
    end

    private

    def fresh?(payload)
      payload.is_a?(Hash) &&
        payload.key?(:stage_movers) &&
        payload.key?(:discharge_movers) &&
        payload.key?(:records)
    end

    def normalize(payload)
      hash = payload.deep_symbolize_keys
      hash[:stage_movers] = Array(hash[:stage_movers])
      hash[:discharge_movers] = Array(hash[:discharge_movers])
      hash[:records] = Array(hash[:records])
      hash
    end

    def listed?(rows, site)
      Array(rows).any? { |row| row[:site_number].to_s == site }
    end

    def compute
      movers = rank_movers(mover_candidates)
      {
        stage_movers: movers[:stage],
        discharge_movers: movers[:discharge],
        records: rank_records(record_candidates),
        computed_at: Time.current.iso8601
      }
    end

    def mover_candidates
      rows = select_candidates(<<~SQL.squish, TIP_MAX_AGE.ago)
        SELECT ts.id AS time_series_id,
               ts.measurement_kind,
               ts.parameter_code,
               ts.primary_series,
               ml.id AS location_id,
               ml.site_number,
               ml.display_name,
               ml.slug,
               ml.state_code,
               ml.state_name,
               lo.value AS current_value,
               lo.unit_of_measure,
               lo.observed_at
        FROM time_series ts
        INNER JOIN latest_observations lo ON lo.time_series_id = ts.id
        INNER JOIN monitoring_locations ml ON ml.id = ts.monitoring_location_id
        WHERE ts.selected_for_display = TRUE
          AND ml.active = TRUE
          AND lo.observed_at >= ?
          AND ts.measurement_kind IN ('water_level', 'discharge')
          AND (
            ts.measurement_kind = 'discharge'
            OR ts.parameter_code = ml.latest_water_level_parameter_code
          )
      SQL
      one_per_station_kind(rows)
    end

    def record_candidates
      rows = select_candidates(<<~SQL.squish, MonitoringLocation::STALE_AFTER.ago, RECORD_MIN_WATER_YEARS)
        SELECT ts.id AS time_series_id,
               ts.measurement_kind,
               ts.parameter_code,
               ts.primary_series,
               ml.id AS location_id,
               ml.site_number,
               ml.display_name,
               ml.slug,
               ml.state_code,
               ml.state_name,
               lo.value AS current_value,
               lo.unit_of_measure,
               lo.observed_at,
               MAX(po.value) AS peak_value,
               MIN(po.water_year) AS year_min,
               MAX(po.water_year) AS year_max,
               COUNT(DISTINCT po.water_year) AS year_count
        FROM time_series ts
        INNER JOIN latest_observations lo ON lo.time_series_id = ts.id
        INNER JOIN monitoring_locations ml ON ml.id = ts.monitoring_location_id
        INNER JOIN peak_observations po
          ON po.time_series_id = ts.id AND po.peak_kind = 'high'
        WHERE ts.selected_for_display = TRUE
          AND ml.active = TRUE
          AND lo.observed_at >= ?
          AND ts.measurement_kind IN ('water_level', 'discharge')
          AND (
            ts.measurement_kind = 'discharge'
            OR ts.parameter_code = ml.latest_water_level_parameter_code
          )
        GROUP BY ts.id, ts.measurement_kind, ts.parameter_code, ts.primary_series,
                 ml.id, ml.site_number, ml.display_name, ml.slug, ml.state_code, ml.state_name,
                 lo.value, lo.unit_of_measure, lo.observed_at
        HAVING COUNT(DISTINCT po.water_year) >= ?
           AND lo.value > MAX(po.value)
      SQL
      one_per_station_kind(rows)
    end

    def select_candidates(sql, *binds)
      quoted = ActiveRecord::Base.sanitize_sql_array([ sql, *binds ])
      MonitoringLocation.connection.select_all(quoted).filter_map { |row| candidate_hash(row) }
    end

    def candidate_hash(row)
      observed_at = coerce_time(row["observed_at"])
      return if observed_at.blank?

      {
        time_series_id: row["time_series_id"].to_i,
        kind: row["measurement_kind"].to_s,
        parameter_code: row["parameter_code"].to_s,
        primary: truthy?(row["primary_series"]),
        location_id: row["location_id"].to_i,
        site_number: row["site_number"].to_s,
        name: row["display_name"].to_s,
        slug: row["slug"].to_s,
        state_code: row["state_code"].to_s,
        state_name: row["state_name"].to_s,
        current_value: row["current_value"].to_f,
        unit: row["unit_of_measure"].to_s,
        observed_at: observed_at,
        peak_value: row["peak_value"]&.to_f,
        year_min: row["year_min"]&.to_i,
        year_max: row["year_max"]&.to_i,
        year_count: row["year_count"]&.to_i
      }
    end

    def one_per_station_kind(rows)
      rows.group_by { |row| [ row[:location_id], row[:kind] ] }.map do |_key, group|
        group.min_by { |row| [ row[:primary] ? 0 : 1, row[:time_series_id] ] }
      end
    end

    def rank_movers(candidates)
      priors = prior_values_for(candidates)
      stage = []
      discharge = []

      candidates.each do |row|
        prior = priors[row[:time_series_id]]
        next if prior.nil?

        delta = row[:current_value] - prior
        next unless delta.positive?

        percent = prior.zero? ? nil : (delta / prior) * 100.0
        entry = row.merge(delta: delta, percent: percent)
        if row[:kind] == "water_level"
          stage << entry
        elsif prior >= DISCHARGE_PRIOR_FLOOR
          discharge << entry
        end
      end

      {
        stage: stage.sort_by { |row| [ -row[:delta], row[:site_number] ] }.first(LIST_LIMIT).map { |row| public_row(row) },
        discharge: discharge.sort_by { |row| [ -row[:percent].to_f, row[:site_number] ] }.first(LIST_LIMIT).map { |row| public_row(row) }
      }
    end

    def prior_values_for(candidates)
      found = {}
      candidates.each_slice(PRIOR_CHUNK) do |slice|
        found.merge!(prior_window_values(slice))
      end
      found
    end

    # Closest continuous point to (tip - PRIOR_HOURS), inside PRIOR_BAND.
    # That is the newest-or-nearest reading from 30 hours before the tip
    # through 18 hours before the tip. Ties go to the newer point.
    def prior_window_values(candidates)
      return {} if candidates.empty?

      ids = candidates.map { |row| row[:time_series_id] }
      cutoffs = candidates.map { |row| row[:observed_at] - PRIOR_HOURS.hours }
      band_hours = PRIOR_BAND.in_hours.to_i
      sql = ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            SELECT DISTINCT ON (c.time_series_id) c.time_series_id, c.value
            FROM continuous_observations c
            INNER JOIN unnest(ARRAY[?]::bigint[], ARRAY[?]::timestamptz[])
              AS cutoffs(time_series_id, cutoff)
              ON c.time_series_id = cutoffs.time_series_id
            WHERE c.observed_at >= cutoffs.cutoff - (? * INTERVAL '1 hour')
              AND c.observed_at <= cutoffs.cutoff + (? * INTERVAL '1 hour')
            ORDER BY c.time_series_id,
                     abs(EXTRACT(EPOCH FROM (c.observed_at - cutoffs.cutoff))),
                     c.observed_at DESC
          SQL
          ids,
          cutoffs.map(&:utc),
          band_hours,
          band_hours
        ]
      )
      ContinuousObservation.connection.select_all(sql).each_with_object({}) do |row, acc|
        acc[row["time_series_id"].to_i] = row["value"].to_f
      end
    end

    def rank_records(rows)
      stage, discharge = rows.partition { |row| row[:kind] == "water_level" }
      stage_rows = stage.sort_by { |row| [ -row_margin(row), row[:site_number] ] }.first(LIST_LIMIT)
      discharge_rows = discharge.sort_by { |row| [ -record_percent(row), row[:site_number] ] }.first(LIST_LIMIT)
      (stage_rows + discharge_rows).map { |row| public_row(row) }
    end

    def row_margin(row)
      row[:current_value].to_f - row[:peak_value].to_f
    end

    def record_percent(row)
      peak = row[:peak_value].to_f
      margin = row_margin(row)
      return margin if peak <= 0

      (margin / peak) * 100.0
    end

    def public_row(row)
      margin = row[:peak_value].nil? ? nil : row_margin(row)
      {
        site_number: row[:site_number],
        name: row[:name],
        path: gauge_path(row),
        state_code: row[:state_code],
        state_name: row[:state_name],
        kind: row[:kind],
        label: kind_label(row),
        unit: UnitLabel.format(row[:unit]).presence || row[:unit],
        precision: row[:kind] == "discharge" ? 0 : 2,
        current_value: row[:current_value].to_f,
        delta: row[:delta],
        percent: row[:percent],
        observed_at: row[:observed_at].iso8601,
        peak_value: row[:peak_value],
        year_min: row[:year_min],
        year_max: row[:year_max],
        margin: margin
      }
    end

    def kind_label(row)
      if row[:kind] == "discharge"
        "Flow"
      else
        ParameterLabels.label_for(row[:parameter_code], fallback: "Gage height")
      end
    end

    def gauge_path(row)
      Rails.application.routes.url_helpers.gauge_path(
        row[:state_code].downcase,
        "#{row[:site_number]}-#{row[:slug]}"
      )
    end

    def coerce_time(value)
      case value
      when Time, ActiveSupport::TimeWithZone, DateTime then value
      when String then Time.zone.parse(value)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def truthy?(value)
      value == true || value == "t" || value == "true" || value == 1
    end
  end
end
