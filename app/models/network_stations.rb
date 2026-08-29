class NetworkStations
  DISTANCE_KM = 80
  PER_SIDE = 2
  ON_FLOWPATH_M = 400
  FRESH_AFTER = 7.days
  METERS_PER_DEG_LAT = 111_320.0
  UPSTREAM = "UM"
  DOWNSTREAM = "DM"

  def self.refresh(scope = MonitoringLocation.all, client: Nldi::Client.new, force: false)
    locations = scope.is_a?(Array) ? scope : scope.to_a
    return 0 if locations.empty?

    id_by_usgs = MonitoringLocation.pluck(:usgs_monitoring_location_id, :id).to_h
    latlon_by_id = MonitoringLocation.pluck(:id, :latitude, :longitude)
      .to_h { |id, lat, lon| [ id, [ lat.to_f, lon.to_f ] ] }
    catalog_ids = id_by_usgs.values.to_set

    refreshed = 0
    locations.each do |location|
      next unless force || stale?(location, catalog_ids)

      refresh_one(
        location,
        client: client,
        id_by_usgs: id_by_usgs,
        latlon_by_id: latlon_by_id
      )
      refreshed += 1
    end
    refreshed
  end

  def self.refresh_one(location, client: Nldi::Client.new, id_by_usgs: nil, latlon_by_id: nil)
    id_by_usgs ||= MonitoringLocation.pluck(:usgs_monitoring_location_id, :id).to_h
    latlon_by_id ||= MonitoringLocation.pluck(:id, :latitude, :longitude)
      .to_h { |id, lat, lon| [ id, [ lat.to_f, lon.to_f ] ] }

    upstream = neighbors_for(
      location,
      mode: UPSTREAM,
      client: client,
      id_by_usgs: id_by_usgs,
      latlon_by_id: latlon_by_id
    )
    downstream = neighbors_for(
      location,
      mode: DOWNSTREAM,
      client: client,
      id_by_usgs: id_by_usgs,
      latlon_by_id: latlon_by_id
    )

    location.update_columns(
      upstream_station_ids: upstream,
      downstream_station_ids: downstream,
      network_synced_at: Time.current,
      updated_at: Time.current
    )
    [ upstream, downstream ]
  end

  def self.stale?(location, catalog_ids)
    return true if location.network_synced_at.blank?
    return true if location.network_synced_at < FRESH_AFTER.ago

    stored = Array(location.upstream_station_ids) + Array(location.downstream_station_ids)
    stored.any? { |id| !catalog_ids.include?(id) }
  end

  def self.neighbors_for(location, mode:, client:, id_by_usgs:, latlon_by_id:)
    sites = client.navigate_sites(
      location.usgs_monitoring_location_id,
      mode: mode,
      distance_km: DISTANCE_KM
    )
    return [] if sites.empty?

    origin = origin_feature(sites, location.usgs_monitoring_location_id)
    candidates = catalog_candidates(sites, location, id_by_usgs, origin, mode)
    return [] if candidates.empty?

    flowlines = client.navigate_flowlines(
      location.usgs_monitoring_location_id,
      mode: mode,
      distance_km: DISTANCE_KM
    )
    return [] if flowlines.empty?

    comid_index = flowline_comid_index(flowlines)
    kept = candidates.filter_map do |candidate|
      next unless on_flowpath?(candidate[:id], latlon_by_id, flowlines)

      index = comid_index[candidate[:comid]]
      next if index.nil?

      candidate.merge(index: index)
    end

    sort_along_network!(kept, mode)
    kept.first(PER_SIDE).map { |row| row[:id] }
  end
  private_class_method :neighbors_for

  def self.origin_feature(sites, usgs_id)
    sites.find { |feature| feature_identifier(feature) == usgs_id.to_s }
  end
  private_class_method :origin_feature

  def self.catalog_candidates(sites, location, id_by_usgs, origin, mode)
    origin_comid = comid_for(origin)
    origin_measure = measure_for(origin)

    sites.filter_map do |feature|
      usgs_id = feature_identifier(feature)
      next if usgs_id.blank? || usgs_id == location.usgs_monitoring_location_id

      db_id = id_by_usgs[usgs_id]
      next unless db_id

      comid = comid_for(feature)
      next if comid.blank?

      measure = measure_for(feature)
      if origin_comid.present? && comid == origin_comid && origin_measure
        next unless on_origin_side?(measure, origin_measure, mode)
      end

      { id: db_id, comid: comid, measure: measure || 0.0 }
    end
  end
  private_class_method :catalog_candidates

  def self.on_origin_side?(measure, origin_measure, mode)
    return false if measure.nil?

    if mode == UPSTREAM
      measure > origin_measure
    else
      measure < origin_measure
    end
  end
  private_class_method :on_origin_side?

  def self.flowline_comid_index(flowlines)
    index = {}
    flowlines.each_with_index do |feature, i|
      comid = flowline_comid(feature)
      next if comid.blank?

      index[comid] = i unless index.key?(comid)
    end
    index
  end
  private_class_method :flowline_comid_index

  def self.sort_along_network!(rows, mode)
    rows.sort_by! do |row|
      measure = row[:measure].to_f
      [ row[:index], mode == UPSTREAM ? measure : -measure ]
    end
  end
  private_class_method :sort_along_network!

  def self.on_flowpath?(location_id, latlon_by_id, flowlines)
    coords = latlon_by_id[location_id]
    return false unless coords

    lat, lon = coords
    distance_m_to_flowlines(lat, lon, flowlines) <= ON_FLOWPATH_M
  end
  private_class_method :on_flowpath?

  def self.distance_m_to_flowlines(lat, lon, flowlines)
    min = Float::INFINITY
    flowlines.each do |feature|
      each_segment(feature) do |lat1, lon1, lat2, lon2|
        d = point_to_segment_m(lat, lon, lat1, lon1, lat2, lon2)
        min = d if d < min
      end
    end
    min
  end
  private_class_method :distance_m_to_flowlines

  def self.each_segment(feature)
    geometry = feature["geometry"] || feature[:geometry]
    return if geometry.blank?

    rings = line_rings(geometry)
    rings.each do |ring|
      ring.each_cons(2) do |a, b|
        lon1, lat1 = a[0].to_f, a[1].to_f
        lon2, lat2 = b[0].to_f, b[1].to_f
        yield lat1, lon1, lat2, lon2
      end
    end
  end
  private_class_method :each_segment

  def self.line_rings(geometry)
    type = geometry["type"] || geometry[:type]
    coords = geometry["coordinates"] || geometry[:coordinates]
    return [] if coords.blank?

    case type.to_s
    when "LineString"
      [ coords ]
    when "MultiLineString"
      coords
    else
      []
    end
  end
  private_class_method :line_rings

  def self.point_to_segment_m(plat, plon, alat, alon, blat, blon)
    cos = Math.cos(NearbyStations.to_rad(plat))
    ax = (alon - plon) * cos * METERS_PER_DEG_LAT
    ay = (alat - plat) * METERS_PER_DEG_LAT
    bx = (blon - plon) * cos * METERS_PER_DEG_LAT
    by = (blat - plat) * METERS_PER_DEG_LAT
    dx = bx - ax
    dy = by - ay
    len2 = (dx * dx) + (dy * dy)
    return Math.hypot(ax, ay) if len2 < 1e-12

    t = ((-ax * dx) + (-ay * dy)) / len2
    t = t.clamp(0.0, 1.0)
    Math.hypot(ax + (t * dx), ay + (t * dy))
  end
  private_class_method :point_to_segment_m

  def self.feature_identifier(feature)
    props = feature_properties(feature)
    (feature["id"] || feature[:id] || props["identifier"] || props[:identifier]).to_s.presence
  end
  private_class_method :feature_identifier

  def self.comid_for(feature)
    return if feature.blank?

    props = feature_properties(feature)
    raw = props["comid"] || props[:comid]
    raw&.to_s.presence
  end
  private_class_method :comid_for

  def self.flowline_comid(feature)
    props = feature_properties(feature)
    raw = props["nhdplus_comid"] || props[:nhdplus_comid] || feature["id"] || feature[:id]
    raw&.to_s.presence
  end
  private_class_method :flowline_comid

  def self.measure_for(feature)
    return if feature.blank?

    props = feature_properties(feature)
    raw = props["measure"] || props[:measure]
    raw&.to_f
  end
  private_class_method :measure_for

  def self.feature_properties(feature)
    feature["properties"] || feature[:properties] || {}
  end
  private_class_method :feature_properties
end
