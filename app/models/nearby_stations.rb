class NearbyStations
  EARTH_RADIUS_KM = 6371.0
  GRID_DEG = 0.5
  NEAREST_SEARCH_DEG = 2.0

  def self.refresh_all
    locations = MonitoringLocation.pluck(:id, :latitude, :longitude)
    return if locations.empty?

    grid = build_grid(locations)
    locations.each do |id, lat, lon|
      candidates = candidates_for(lat.to_f, lon.to_f, grid)
      nearest = nearest_ids(id, lat.to_f, lon.to_f, candidates, limit: 4)
      MonitoringLocation.where(id: id).update_all(nearby_station_ids: nearest, updated_at: Time.current)
    end
  end

  def self.nearest_to(lat, lon)
    lat = lat.to_f
    lon = lon.to_f
    return if lat.zero? && lon.zero?
    return unless lat.between?(-90, 90) && lon.between?(-180, 180)

    pad = NEAREST_SEARCH_DEG
    scope = MonitoringLocation.in_bbox(lon - pad, lat - pad, lon + pad, lat + pad)
    scope = MonitoringLocation.all if scope.none?

    scope.min_by do |loc|
      haversine_km(lat, lon, loc.latitude.to_f, loc.longitude.to_f)
    end
  end

  def self.nearest_ids(id, lat, lon, all, limit: 4)
    all
      .reject { |other_id, _, _| other_id == id }
      .map { |other_id, other_lat, other_lon| [ other_id, haversine_km(lat, lon, other_lat.to_f, other_lon.to_f) ] }
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

  def self.build_grid(locations)
    grid = Hash.new { |h, key| h[key] = [] }
    locations.each do |id, lat, lon|
      key = cell_key(lat.to_f, lon.to_f)
      grid[key] << [ id, lat.to_f, lon.to_f ]
    end
    grid
  end
  private_class_method :build_grid

  def self.candidates_for(lat, lon, grid)
    cell_lat, cell_lon = cell_coords(lat, lon)
    candidates = []
    (-1..1).each do |dlat|
      (-1..1).each do |dlon|
        key = [ cell_lat + dlat, cell_lon + dlon ]
        candidates.concat(grid[key]) if grid.key?(key)
      end
    end
    candidates
  end
  private_class_method :candidates_for

  def self.cell_key(lat, lon)
    cell_coords(lat, lon)
  end
  private_class_method :cell_key

  def self.cell_coords(lat, lon)
    [ (lat / GRID_DEG).floor, (lon / GRID_DEG).floor ]
  end
  private_class_method :cell_coords
end
