class StationSnapshotCache
  PREFIX = "station_snapshot:v1".freeze
  TTL = 2.hours

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
    payload
  end

  def self.warm_stale_batch
    MonitoringLocation.find_each { |location| warm(location) }
  end

  def self.fetch(location)
    read(location) || warm(location)
  end

  def self.build_payload(location)
    series_by_kind = location.time_series.selected.includes(:latest_observation, :peak_observations, :daily_observations, :continuous_observations).index_by(&:measurement_kind)
    current = {}
    extremes = {}
    trends = {}

    series_by_kind.each do |kind, series|
      obs = series.latest_observation
      next unless obs

      current[kind] = {
        value: obs.value.to_f,
        unit: obs.unit_of_measure,
        observed_at: obs.observed_at.iso8601,
        approval_status: obs.approval_status,
        parameter_code: series.parameter_code,
        parameter_description: series.parameter_description
      }

      trend_24h = TrendComparison.for_series(series, current_value: obs.value, observed_at: obs.observed_at)
      yoy = TrendComparison.yoy_for_series(series, current_value: obs.value, observed_at: obs.observed_at)
      trends[kind] = {
        change_24h: trend_24h.delta,
        yoy: yoy.prior_value.nil? ? nil : yoy.delta
      }

      high = series.peak_observations.where(peak_kind: "high").order(value: :desc).first
      low_daily = series.daily_observations.order(:value).first
      extremes[kind] = {
        high: high && { value: high.value.to_f, water_year: high.water_year, observed_at: high.observed_at&.iso8601 },
        low: low_daily && { value: low_daily.value.to_f, observed_on: low_daily.observed_on.iso8601 }
      }
    end

    nearby = MonitoringLocation.where(id: location.nearby_station_ids).map do |n|
      {
        site_number: n.site_number,
        name: n.name,
        state_code: n.state_code,
        slug: n.slug,
        has_water_level: n.has_water_level,
        has_discharge: n.has_discharge,
        has_temperature: n.has_temperature,
        path: "/gauges/#{n.path_state}/#{n.to_param}"
      }
    end

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
      measurement_kinds: location.measurement_kinds,
      current: current,
      trends: trends,
      extremes: extremes,
      nearby: nearby,
      usgs_url: "https://waterdata.usgs.gov/monitoring-location/#{location.usgs_monitoring_location_id}/",
      agency_name: location.agency_code
    }
  end
end
