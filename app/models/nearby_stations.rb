class NearbyStations
  EARTH_RADIUS_KM = 6371.0

  def self.refresh_all
    locations = MonitoringLocation.pluck(:id, :latitude, :longitude)
    locations.each do |id, lat, lon|
      nearest = nearest_ids(id, lat.to_f, lon.to_f, locations, limit: 4)
      MonitoringLocation.where(id: id).update_all(nearby_station_ids: nearest, updated_at: Time.current)
    end
  end

  def self.nearest_ids(id, lat, lon, all, limit: 4)
    all
      .reject { |other_id, _, _| other_id == id }
      .map { |other_id, other_lat, other_lon| [other_id, haversine_km(lat, lon, other_lat.to_f, other_lon.to_f)] }
      .sort_by(&:last)
      .first(limit)
      .map(&:first)
  end

  def self.haversine_km(lat1, lon1, lat2, lon2)
    dlat = to_rad(lat2 - lat1)
    dlon = to_rad(lon2 - lon1)
    a = Math.sin(dlat / 2)**2 + Math.cos(to_rad(lat1)) * Math.cos(to_rad(lat2)) * Math.sin(dlon / 2)**2
    2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(a))
  end

  def self.to_rad(deg)
    deg * Math::PI / 180.0
  end
end
