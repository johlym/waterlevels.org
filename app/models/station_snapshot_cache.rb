class StationSnapshotCache
  PREFIX = "station_snapshot:v5".freeze
  TTL = 2.hours
  MILES_PER_KM = 0.621371

  def self.key_for(location)
    "#{PREFIX}:#{location.site_number}"
  end

  def self.read(location)
    raw = Rails.cache.read(key_for(location))
    raw.is_a?(Hash) ? raw.with_indifferent_access : nil
  end

  def self.warm(location)
    payload = build_payload(location)
    Rails.cache.write(key_for(location), payload, expires_in: TTL)
    payload.with_indifferent_access
  end

  def self.warm_stale_batch
    MonitoringLocation.find_each { |location| warm(location) }
  end

  def self.fetch(location)
    cached = read(location)
    return warm(location) if cached.nil? || stale_snapshot?(cached, location)

    cached
  end

  # Rebuild when empty, or when selected series outnumber cached measurement cards
  # (e.g. after reselect added gage height + elevation).
  def self.stale_snapshot?(cached, location)
    measurements = Array(cached[:measurements])
    selected_count = location.time_series.selected.count
    return true if selected_count.positive? && measurements.size < selected_count

    return false if measurements.any?
    current = cached[:current] || {}
    return false if current.present?

    location.has_water_level? || location.has_discharge? || location.has_temperature?
  end
  private_class_method :stale_snapshot?

  def self.build_payload(location)
    selected = location.time_series.selected
      .includes(:latest_observation, :peak_observations, :daily_observations)
      .to_a
      .sort_by { |s| [ kind_order(s.measurement_kind), Usgs::ParameterCodes.preference_rank(s.parameter_code) ] }

    measurements = selected.filter_map { |series| measurement_payload(series) }
    measurements = denormalized_measurements(location) if measurements.empty?

    current = {}
    trends = {}
    extremes = {}
    measurements.each do |m|
      kind = m[:kind]
      next if current[kind]

      current[kind] = m.slice(:value, :unit, :observed_at, :approval_status, :parameter_code, :parameter_description)
      trends[kind] = m[:trends]
      extremes[kind] = m[:extremes]
    end

    nearby = nearby_payload(location)

    {
      site_number: location.site_number,
      name: location.name,
      slug: location.slug,
      state_code: location.state_code,
      state_name: location.state_name,
      county_name: location.county_name,
      latitude: location.latitude.to_f,
      longitude: location.longitude.to_f,
      stale: location.stale?,
      latest_observed_at: location.latest_observed_at&.iso8601,
      measurement_kinds: measurements.map { |m| m[:kind] }.uniq,
      measurements: measurements,
      current: current,
      trends: trends,
      extremes: extremes,
      nearby: nearby,
      usgs_url: "https://waterdata.usgs.gov/monitoring-location/#{location.usgs_monitoring_location_id}/",
      agency_name: location.agency_code
    }
  end

  def self.measurement_payload(series)
    obs = series.latest_observation
    return unless obs

    trend_24h = TrendComparison.for_series(series, current_value: obs.value, observed_at: obs.observed_at)
    yoy = TrendComparison.yoy_for_series(series, current_value: obs.value, observed_at: obs.observed_at)
    high = series.peak_observations.where(peak_kind: "high").order(value: :desc).first
    low_daily = series.daily_observations.order(:value).first
    label = Usgs::ParameterCodes.label_for(series.parameter_code, fallback: series.parameter_description)

    {
      key: series.parameter_code,
      kind: series.measurement_kind,
      label: label,
      parameter_code: series.parameter_code,
      parameter_description: series.parameter_description,
      value: obs.value.to_f,
      unit: obs.unit_of_measure,
      observed_at: obs.observed_at.iso8601,
      approval_status: obs.approval_status,
      precision: series.measurement_kind == "discharge" ? 0 : 2,
      trends: {
        change_24h: trend_24h.delta,
        yoy: yoy.prior_value.nil? ? nil : yoy.delta
      },
      extremes: {
        high: high && { value: high.value.to_f, water_year: high.water_year, observed_at: high.observed_at&.iso8601 },
        low: low_daily && { value: low_daily.value.to_f, observed_on: low_daily.observed_on.iso8601 }
      }
    }
  end

  def self.denormalized_measurements(location)
    measurements = []
    if location.latest_water_level_value.present?
      code = location.latest_water_level_parameter_code
      measurements << {
        key: code.presence || "water_level",
        kind: "water_level",
        label: Usgs::ParameterCodes.label_for(code, fallback: "Water level"),
        parameter_code: code,
        parameter_description: nil,
        value: location.latest_water_level_value.to_f,
        unit: location.latest_water_level_unit,
        observed_at: location.latest_observed_at&.iso8601,
        approval_status: location.latest_approval_status,
        precision: 2,
        trends: { change_24h: nil, yoy: nil },
        extremes: { high: nil, low: nil }
      }
    end
    if location.latest_discharge_value.present?
      measurements << {
        key: Usgs::ParameterCodes::DISCHARGE,
        kind: "discharge",
        label: "Flow",
        parameter_code: Usgs::ParameterCodes::DISCHARGE,
        parameter_description: nil,
        value: location.latest_discharge_value.to_f,
        unit: location.latest_discharge_unit,
        observed_at: location.latest_observed_at&.iso8601,
        approval_status: location.latest_approval_status,
        precision: 0,
        trends: { change_24h: nil, yoy: nil },
        extremes: { high: nil, low: nil }
      }
    end
    if location.latest_temperature_c.present?
      measurements << {
        key: Usgs::ParameterCodes::TEMPERATURE,
        kind: "temperature",
        label: "Temperature",
        parameter_code: Usgs::ParameterCodes::TEMPERATURE,
        parameter_description: nil,
        value: location.latest_temperature_c.to_f,
        unit: "°C",
        observed_at: location.latest_observed_at&.iso8601,
        approval_status: location.latest_approval_status,
        precision: 1,
        trends: { change_24h: nil, yoy: nil },
        extremes: { high: nil, low: nil }
      }
    end
    measurements
  end

  def self.kind_order(kind)
    { "water_level" => 0, "discharge" => 1, "temperature" => 2 }[kind] || 9
  end

  def self.nearby_payload(location)
    ids = Array(location.nearby_station_ids)
    return [] if ids.empty?

    stations = MonitoringLocation.where(id: ids).index_by(&:id)
    origin_lat = location.latitude.to_f
    origin_lon = location.longitude.to_f

    ids.filter_map do |id|
      n = stations[id]
      next unless n

      distance_mi = NearbyStations.haversine_km(
        origin_lat, origin_lon, n.latitude.to_f, n.longitude.to_f
      ) * MILES_PER_KM

      {
        site_number: n.site_number,
        name: n.name,
        state_code: n.state_code,
        slug: n.slug,
        has_water_level: n.has_water_level,
        has_discharge: n.has_discharge,
        has_temperature: n.has_temperature,
        path: "/gauges/#{n.path_state}/#{n.to_param}",
        distance_mi: distance_mi.round(1),
        stale: n.stale?,
        latest_observed_at: n.latest_observed_at&.iso8601,
        primary: nearby_primary_reading(n)
      }
    end
  end

  def self.nearby_primary_reading(location)
    if location.latest_discharge_value.present?
      {
        kind: "discharge",
        label: "Flow",
        value: location.latest_discharge_value.to_f,
        unit: location.latest_discharge_unit.presence || "ft³/s",
        precision: 0
      }
    elsif location.latest_water_level_value.present?
      {
        kind: "water_level",
        label: "Level",
        value: location.latest_water_level_value.to_f,
        unit: location.latest_water_level_unit.presence || "ft",
        precision: 2
      }
    elsif location.latest_temperature_c.present?
      {
        kind: "temperature",
        label: "Temp",
        value: location.latest_temperature_c.to_f,
        unit: "°C",
        precision: 1
      }
    end
  end

  private_class_method :measurement_payload, :denormalized_measurements, :kind_order,
                       :nearby_payload, :nearby_primary_reading
end
