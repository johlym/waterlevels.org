class StateListingCache
  PREFIX = "state_listing:v3".freeze
  TTL = 6.hours

  def self.key_for(state_code)
    "#{PREFIX}:#{state_code.to_s.downcase}"
  end

  def self.read(state_code)
    Rails.cache.read(key_for(state_code))
  end

  def self.warm(state_code)
    rows = MonitoringLocation.in_state(state_code).ordered_for_state_table.map do |loc|
      {
        site_number: loc.site_number,
        name: loc.name,
        slug: loc.slug,
        county_name: loc.county_name,
        latitude: loc.latitude&.to_f,
        longitude: loc.longitude&.to_f,
        has_water_level: loc.has_water_level,
        has_discharge: loc.has_discharge,
        has_temperature: loc.has_temperature,
        latest_water_level_value: loc.latest_water_level_value&.to_f,
        latest_water_level_unit: UnitLabel.format(loc.latest_water_level_unit),
        latest_discharge_value: loc.latest_discharge_value&.to_f,
        latest_discharge_unit: UnitLabel.format(loc.latest_discharge_unit),
        latest_temperature_c: loc.latest_temperature_c&.to_f,
        latest_observed_at: loc.latest_observed_at&.iso8601,
        stale: loc.stale?,
        path: "/gauges/#{loc.path_state}/#{loc.to_param}"
      }
    end
    state_name = MonitoringLocation.in_state(state_code).limit(1).pick(:state_name)
    payload = {
      state_code: state_code.to_s.downcase,
      state_name: state_name,
      locations: rows,
      total_count: rows.size,
      offline_count: rows.count { |row| row[:stale] }
    }
    Rails.cache.write(key_for(state_code), payload, expires_in: TTL)
    payload
  end

  def self.warm_all
    MonitoringLocation.distinct.pluck(:state_code).each { |code| warm(code) }
  end

  def self.fetch(state_code)
    cached = read(state_code)
    return warm(state_code) if cached.blank?
    return warm(state_code) if cached.is_a?(Hash) && !cached.key?(:total_count) && !cached.key?("total_count")

    cached
  end
end
