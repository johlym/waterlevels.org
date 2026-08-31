class StationSnapshotCache
  PREFIX = "station_snapshot:v14".freeze
  TTL = 2.hours
  MILES_PER_KM = 0.621371

  def self.key_for(location)
    "#{PREFIX}:#{location.site_number}"
  end

  def self.clear!
    Rails.cache.delete_matched("#{PREFIX}:*") if Rails.cache.respond_to?(:delete_matched)
  end

  def self.clear_for(location)
    Rails.cache.delete(key_for(location))
  end

  def self.clear_for_id(id)
    site_number = MonitoringLocation.where(id: id).pick(:site_number)
    return if site_number.blank?

    Rails.cache.delete("#{PREFIX}:#{site_number}")
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

  def self.warm_stale_batch(limit: nil)
    warmed = 0
    MonitoringLocation.includes(:time_series).find_each do |location|
      cached = read(location)
      next unless cached.nil? || stale_snapshot?(cached, location)

      warm(location)
      warmed += 1
      break if limit&.positive? && warmed >= limit
    end
    warmed
  end

  def self.fetch(location)
    Telemetry.in_span(
      "cache.station_snapshot.fetch",
      attributes: {
        "app.operation" => "cache.station_snapshot.fetch",
        "app.site_number" => location.site_number,
        "app.state" => location.state_code,
        "app.location_name" => location.display_name
      }
    ) do
      cached = read(location)
      stale = cached.nil? || stale_snapshot?(cached, location)
      Telemetry.add_attributes("app.cache_hit" => !stale, "app.cache_stale" => !cached.nil? && stale)
      return warm(location) if stale

      cached
    end
  end

  # Rebuild when empty, when selected series and cached measurement cards diverge
  # (reselect added/removed a kind, e.g. discontinued temperature), when on-stream
  # neighbor ids changed, or when a newer datapoint exists than the cached
  # "last updated" timestamp.
  def self.stale_snapshot?(cached, location)
    measurements = Array(cached[:measurements])
    selected = location.time_series.selected
    selected_count = selected.count
    return true if selected_count.positive? && measurements.size < selected_count
    # Deselected params (discontinued tip) must drop off cards/table columns.
    return true if measurements.size > selected_count

    return true if network_mismatch?(cached, location)

    newest_datapoint = newest_collected_at(location)
    if newest_datapoint.present?
      cached_latest = coerce_time(cached[:latest_observed_at])
      # Compare at second precision: cached ISO8601 tips omit subseconds.
      return true if cached_latest.blank? || newest_datapoint.to_i > cached_latest.to_i
    end

    return false if measurements.any?
    current = cached[:current] || {}
    return false if current.present?

    location.has_water_level? || location.has_discharge? || location.has_temperature?
  end

  def self.network_mismatch?(cached, location)
    network = cached[:network] || cached["network"] || {}
    cached_up = Array(network[:upstream] || network["upstream"]).size
    cached_down = Array(network[:downstream] || network["downstream"]).size
    cached_up != Array(location.upstream_station_ids).size ||
      cached_down != Array(location.downstream_station_ids).size
  end
  private_class_method :stale_snapshot?, :network_mismatch?

  def self.build_payload(location)
    selected = location.time_series.selected
      .includes(:latest_observation, :peak_observations, :daily_observations)
      .to_a
      .sort_by { |s| [ kind_order(s.measurement_kind), Usgs::ParameterCodes.preference_rank(s.parameter_code) ] }

    prior_24h_by_series_id = TrendComparison.prior_24h_continuous_by_series(selected)
    measurements = selected.filter_map do |series|
      measurement_payload(series, prior_continuous: prior_24h_by_series_id[series.id])
    end
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

    neighbor_cards = neighbor_cards_for(location)
    nearby = neighbor_cards[:nearby]
    network = { upstream: neighbor_cards[:upstream], downstream: neighbor_cards[:downstream] }
    latest_observed_at = latest_observed_at_for(measurements, location)

    {
      site_number: location.site_number,
      name: location.display_name,
      slug: location.slug,
      state_code: location.state_code,
      state_name: location.state_name,
      county_name: location.county_name,
      latitude: location.latitude.to_f,
      longitude: location.longitude.to_f,
      time_zone: location.time_zone,
      time_zone_identifier: location.time_zone_identifier,
      stale: location.stale?,
      latest_observed_at: latest_observed_at,
      nwps_matched: location.nwps_matched,
      nwps_lid: location.nwps_lid,
      flood_category: location.flood_category,
      flood_category_label: location.flood_category_label,
      flood_alert: location.flood_alert?,
      flood_category_observed_at: location.flood_category_observed_at&.iso8601,
      flood_stages: {
        action: location.flood_stage_action&.to_f,
        minor: location.flood_stage_minor&.to_f,
        moderate: location.flood_stage_moderate&.to_f,
        major: location.flood_stage_major&.to_f
      },
      measurement_kinds: measurements.map { |m| m[:kind] }.uniq,
      measurements: measurements,
      current: current,
      trends: trends,
      extremes: extremes,
      nearby: nearby,
      network: network,
      usgs_url: "https://waterdata.usgs.gov/monitoring-location/#{location.usgs_monitoring_location_id}/",
      agency_name: location.agency_code
    }
  end

  # Prefer the newest observation among displayed measurements so "Last updated"
  # tracks datapoints even when the denormalized location column lags.
  def self.latest_observed_at_for(measurements, location)
    from_measurements = Array(measurements).filter_map { |m| coerce_time(m[:observed_at] || m["observed_at"]) }.max
    (from_measurements || location.latest_observed_at)&.iso8601
  end
  private_class_method :latest_observed_at_for

  def self.newest_collected_at(location)
    selected_ids = location.time_series.selected.select(:id)
    [
      LatestObservation.where(time_series_id: selected_ids).maximum(:observed_at),
      location.latest_observed_at
    ].compact.max
  end
  private_class_method :newest_collected_at

  def self.coerce_time(value)
    case value
    when Time, ActiveSupport::TimeWithZone, DateTime then value
    when String then Time.zone.parse(value)
    end
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :coerce_time

  def self.measurement_payload(series, prior_continuous: :lookup)
    obs = series.latest_observation
    return unless obs

    # Prefer preloaded associations / batched continuous priors so gauge show
    # does not N+1 across selected time series (Sentry WATER-4).
    trend_24h = TrendComparison.for_series(
      series,
      current_value: obs.value,
      observed_at: obs.observed_at,
      prior_continuous: prior_continuous
    )
    yoy = TrendComparison.yoy_for_series(series, current_value: obs.value, observed_at: obs.observed_at)
    high = if series.association(:peak_observations).loaded?
      series.peak_observations.select { |p| p.peak_kind == "high" }.max_by { |p| p.value.to_f }
    else
      series.peak_observations.where(peak_kind: "high").order(value: :desc).first
    end
    low_daily = lowest_daily_payload(series)
    label = Usgs::ParameterCodes.label_for(series.parameter_code, fallback: series.parameter_description)

    {
      key: series.parameter_code,
      kind: series.measurement_kind,
      label: label,
      parameter_code: series.parameter_code,
      parameter_description: series.parameter_description,
      value: obs.value.to_f,
      unit: UnitLabel.format(obs.unit_of_measure),
      observed_at: obs.observed_at.iso8601,
      approval_status: obs.approval_status,
      precision: series.measurement_kind == "discharge" ? 0 : 2,
      trends: {
        change_24h: trend_24h.delta,
        yoy: yoy.prior_value.nil? ? nil : yoy.delta
      },
      extremes: {
        high: high && { value: high.value.to_f, water_year: high.water_year, observed_at: high.observed_at&.iso8601 },
        low: low_daily
      }
    }
  end

  def self.lowest_daily_payload(series)
    if DailyArchive.reads_enabled?
      points = DailyArchive::Reader.new.points_for(
        time_series_id: series.id,
        start_on: 1.year.ago.to_date,
        end_on: Date.current
      )
      if points.any?
        low = points.min_by { |p| p[:v] }
        return { value: low[:v].to_f, observed_on: low[:t] }
      end
    end

    row = if series.association(:daily_observations).loaded?
      series.daily_observations.min_by { |d| d.value.to_f }
    else
      series.daily_observations.order(:value).first
    end
    return unless row

    { value: row.value.to_f, observed_on: row.observed_on.iso8601 }
  end
  private_class_method :lowest_daily_payload

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
        unit: UnitLabel.format(location.latest_water_level_unit),
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
        unit: UnitLabel.format(location.latest_discharge_unit),
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

  def self.neighbor_cards_for(location)
    nearby_ids = Array(location.nearby_station_ids)
    up_ids = Array(location.upstream_station_ids)
    down_ids = Array(location.downstream_station_ids)
    all_ids = (nearby_ids + up_ids + down_ids).uniq
    stations = all_ids.empty? ? {} : MonitoringLocation.where(id: all_ids).index_by(&:id)
    origin_lat = location.latitude.to_f
    origin_lon = location.longitude.to_f

    {
      nearby: neighbor_cards_from(nearby_ids, stations, origin_lat, origin_lon),
      upstream: neighbor_cards_from(up_ids, stations, origin_lat, origin_lon),
      downstream: neighbor_cards_from(down_ids, stations, origin_lat, origin_lon)
    }
  end

  def self.neighbor_cards_from(ids, stations, origin_lat, origin_lon)
    Array(ids).filter_map do |id|
      n = stations[id]
      next unless n

      neighbor_card(n, origin_lat: origin_lat, origin_lon: origin_lon)
    end
  end

  def self.neighbor_card(n, origin_lat:, origin_lon:)
    distance_mi = NearbyStations.haversine_km(
      origin_lat, origin_lon, n.latitude.to_f, n.longitude.to_f
    ) * MILES_PER_KM

    {
      site_number: n.site_number,
      name: n.display_name,
      state_code: n.state_code,
      slug: n.slug,
      has_water_level: n.has_water_level,
      has_discharge: n.has_discharge,
      has_temperature: n.has_temperature,
      path: "/gauges/#{n.path_state}/#{n.to_param}",
      distance_mi: distance_mi.round(1),
      stale: n.stale?,
      flood_category: n.flood_category,
      flood_category_label: n.flood_category_label,
      latest_observed_at: n.latest_observed_at&.iso8601,
      measurements: nearby_readings(n)
    }
  end

  def self.nearby_readings(location)
    readings = []
    if location.latest_discharge_value.present?
      readings << {
        kind: "discharge",
        label: "Flow",
        value: location.latest_discharge_value.to_f,
        unit: UnitLabel.format(location.latest_discharge_unit.presence || "ft³/s"),
        precision: 0
      }
    end
    if location.latest_water_level_value.present?
      readings << {
        kind: "water_level",
        label: "Level",
        value: location.latest_water_level_value.to_f,
        unit: UnitLabel.format(location.latest_water_level_unit.presence || "ft"),
        precision: 2
      }
    end
    if location.latest_temperature_c.present?
      readings << {
        kind: "temperature",
        label: "Temp",
        value: location.latest_temperature_c.to_f,
        unit: "°C",
        precision: 1
      }
    end
    readings
  end

  private_class_method :measurement_payload, :denormalized_measurements, :kind_order,
                       :neighbor_cards_for, :neighbor_cards_from, :neighbor_card,
                       :nearby_readings
end
