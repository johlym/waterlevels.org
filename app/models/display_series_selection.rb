class DisplaySeriesSelection
  def self.apply!(location)
    series = location.time_series.includes(:latest_observation).to_a

    water_levels = pick_water_levels(series)
    discharge = pick_one(series, "discharge")
    temperature = pick_one(series, "temperature")
    selected = water_levels + [ discharge, temperature ].compact
    selected_ids = selected.map(&:id)

    location.time_series.update_all(selected_for_display: false)
    TimeSeries.where(id: selected_ids).update_all(selected_for_display: true) if selected_ids.any?

    preferred_water_level = water_levels.first
    location.update!(
      has_water_level: preferred_water_level.present?,
      has_discharge: discharge.present?,
      has_temperature: temperature.present?,
      latest_water_level_value: latest_value_for(preferred_water_level),
      latest_water_level_parameter_code: preferred_water_level&.parameter_code,
      latest_water_level_unit: latest_unit_for(preferred_water_level),
      latest_discharge_value: latest_value_for(discharge),
      latest_discharge_unit: latest_unit_for(discharge),
      latest_temperature_c: latest_value_for(temperature),
      latest_observed_at: selected.map { |s| s.latest_observation&.observed_at }.compact.max,
      latest_approval_status: selected.map { |s| s.latest_observation&.approval_status }.compact.first
    )
    location
  end

  def self.pick_water_levels(series)
    series
      .select { |s| s.measurement_kind == "water_level" }
      .group_by(&:parameter_code)
      .map { |_code, group| group.find(&:primary_series?) || group.first }
      .sort_by { |s| Usgs::ParameterCodes.preference_rank(s.parameter_code) }
  end
  private_class_method :pick_water_levels

  def self.pick_one(series, kind)
    series.find { |s| s.measurement_kind == kind && s.primary_series? } ||
      series.find { |s| s.measurement_kind == kind }
  end
  private_class_method :pick_one

  def self.latest_value_for(series)
    series&.latest_observation&.value
  end
  private_class_method :latest_value_for

  def self.latest_unit_for(series)
    series&.latest_observation&.unit_of_measure || series&.unit_of_measure
  end
  private_class_method :latest_unit_for
end
