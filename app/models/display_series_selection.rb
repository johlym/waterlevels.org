class DisplaySeriesSelection
  def self.apply!(location)
    series = location.time_series.includes(:latest_observation).to_a
    station_reporting = series.any?(&:reporting?)

    water_levels = pick_water_levels(series, station_reporting: station_reporting)
    discharge = pick_one(series, "discharge", station_reporting: station_reporting)
    temperature = pick_one(series, "temperature", station_reporting: station_reporting)
    selected = water_levels + [ discharge, temperature ].compact
    selected_ids = selected.map(&:id)

    location.time_series.update_all(selected_for_display: false)
    TimeSeries.where(id: selected_ids).update_all(selected_for_display: true) if selected_ids.any?

    preferred_water_level = water_levels.first
    location.update!(
      has_water_level: preferred_water_level.present?,
      has_discharge: discharge.present?,
      has_temperature: temperature.present?
    )
    denormalize!(location, selected: selected)
  end

  # Tip hash derived from selected series' LatestObservation rows (no write).
  def self.tip_attributes(location, selected: nil)
    selected ||= location.time_series.selected.includes(:latest_observation).to_a
    attrs = {
      latest_water_level_value: nil,
      latest_water_level_parameter_code: nil,
      latest_water_level_unit: nil,
      latest_discharge_value: nil,
      latest_discharge_unit: nil,
      latest_temperature_c: nil,
      latest_observed_at: nil,
      latest_approval_status: nil
    }

    water_levels = selected
      .select { |s| s.measurement_kind == "water_level" && s.latest_observation }
      .sort_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
    preferred_water_level = water_levels.first

    if preferred_water_level
      obs = preferred_water_level.latest_observation
      attrs[:latest_water_level_value] = obs.value
      attrs[:latest_water_level_parameter_code] = preferred_water_level.parameter_code
      attrs[:latest_water_level_unit] = obs.unit_of_measure
      attrs[:latest_approval_status] = obs.approval_status
    end

    times = []
    selected.each do |series|
      obs = series.latest_observation
      next unless obs

      times << obs.observed_at
      case series.measurement_kind
      when "discharge"
        attrs[:latest_discharge_value] = obs.value
        attrs[:latest_discharge_unit] = obs.unit_of_measure
        attrs[:latest_approval_status] ||= obs.approval_status
      when "temperature"
        # Skip USGS sentinel / fault values (e.g. -100000) that overflow decimal(8,3).
        if Usgs::ParameterCodes.plausible_temperature_c?(obs.value)
          attrs[:latest_temperature_c] = obs.value
          attrs[:latest_approval_status] ||= obs.approval_status
        end
      end
    end
    attrs[:latest_observed_at] = times.compact.max
    attrs
  end

  # Rewrite denormalized map/listing tip columns from selected series tips.
  # Safe to call after LatestObservation upserts without re-running selection.
  def self.denormalize!(location, selected: nil)
    location.update!(tip_attributes(location, selected: selected))
    location
  end

  def self.pick_water_levels(series, station_reporting:)
    series
      .select { |s| s.measurement_kind == "water_level" }
      .group_by(&:parameter_code)
      .filter_map do |_code, group|
        pool = filter_for_display(group, station_reporting: station_reporting)
        pool.find(&:primary_series?) || pool.first
      end
      .sort_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
  end
  private_class_method :pick_water_levels

  def self.pick_one(series, kind, station_reporting:)
    candidates = series.select { |s| s.measurement_kind == kind }
    pool = filter_for_display(candidates, station_reporting: station_reporting)
    pool.find(&:primary_series?) || pool.first
  end
  private_class_method :pick_one

  # Prefer series with a fresh tip. When the station is still reporting other
  # kinds, omit stale candidates entirely so discontinued parameters (e.g.
  # temperature that USGS stopped publishing) no longer drive Partial rows,
  # has_* flags, or history-backfill gates. If the whole station is quiet,
  # keep the last-known series so stale gauge pages still show last values.
  def self.filter_for_display(candidates, station_reporting:)
    return [] if candidates.empty?

    active = candidates.select(&:reporting?)
    return active if active.any?
    return [] if station_reporting

    candidates
  end
  private_class_method :filter_for_display
end
