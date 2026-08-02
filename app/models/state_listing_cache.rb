class StateListingCache
  PREFIX = "state_listing:v1".freeze
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
        has_water_level: loc.has_water_level,
        has_discharge: loc.has_discharge,
        has_temperature: loc.has_temperature,
        path: "/gauges/#{loc.path_state}/#{loc.to_param}"
      }
    end
    state_name = MonitoringLocation.in_state(state_code).limit(1).pick(:state_name)
    payload = {
      state_code: state_code.to_s.downcase,
      state_name: state_name,
      locations: rows
    }
    Rails.cache.write(key_for(state_code), payload, expires_in: TTL)
    payload
  end

  def self.warm_all
    MonitoringLocation.distinct.pluck(:state_code).each { |code| warm(code) }
  end

  def self.fetch(state_code)
    read(state_code) || warm(state_code)
  end
end
