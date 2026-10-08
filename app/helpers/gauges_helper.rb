module GaugesHelper
  FLOOD_WATCH_CATEGORIES = %w[action minor moderate major].freeze

  def related_station_fields(node)
    {
      stale: node[:stale] || node["stale"],
      distance: node[:distance_mi] || node["distance_mi"],
      site: node[:site_number] || node["site_number"],
      name: node[:name] || node["name"],
      path: node[:path] || node["path"],
      flood_category: node[:flood_category] || node["flood_category"],
      observed_at: node[:latest_observed_at] || node["latest_observed_at"],
      readings: related_station_readings(node)
    }
  end

  def related_station_stale?(node)
    value = node.is_a?(Hash) ? (node[:stale] || node["stale"]) : nil
    value == true || value.to_s == "true"
  end

  def related_station_watch?(category)
    FLOOD_WATCH_CATEGORIES.include?(category.to_s)
  end

  def related_station_readings(node)
    readings = Array(node[:measurements] || node["measurements"])
    return readings if readings.any?

    primary = node[:primary] || node["primary"]
    primary.present? ? [ primary ] : []
  end

  # Plot points for the station-page map. Upstream is stored nearest-first, so
  # it is reversed into far-to-near order before downstream. A gauge that is
  # both nearby and on-stream is drawn once, as upstream or downstream.
  def related_map_payload(upstream:, downstream:, nearby:, current:)
    origin = related_map_current(current)
    return if origin.nil?

    seen = {}
    seen[origin[:site_number]] = true if origin[:site_number].present?
    stations = []
    related_map_append!(stations, seen, Array(upstream).reverse, "upstream")
    related_map_append!(stations, seen, downstream, "downstream")
    related_map_append!(stations, seen, nearby, "nearby")
    return if stations.empty?

    { current: origin, stations: stations }
  end

  private

  def related_map_current(node)
    point = related_map_point(node, role: "current")
    return if point.nil?

    point.slice(:site_number, :name, :lat, :lon)
  end

  def related_map_append!(stations, seen, nodes, role)
    Array(nodes).each do |node|
      point = related_map_point(node, role: role)
      next if point.nil?
      next if point[:site_number].present? && seen[point[:site_number]]

      seen[point[:site_number]] = true if point[:site_number].present?
      stations << point
    end
  end

  def related_map_point(node, role:)
    return if node.blank?

    lat = related_map_float(node[:latitude] || node["latitude"])
    lon = related_map_float(node[:longitude] || node["longitude"])
    return if lat.nil? || lon.nil?
    return unless lat.between?(-90, 90) && lon.between?(-180, 180)

    category = (node[:flood_category] || node["flood_category"]).to_s
    {
      site_number: (node[:site_number] || node["site_number"]).to_s,
      name: (node[:name] || node["name"]).to_s,
      path: (node[:path] || node["path"]).presence,
      lat: lat,
      lon: lon,
      role: role,
      distance_mi: related_map_float(node[:distance_mi] || node["distance_mi"]),
      flood_category: category.presence,
      flood_alert: FLOOD_WATCH_CATEGORIES.include?(category)
    }
  end

  def related_map_float(value)
    return if value.nil? || (value.is_a?(String) && value.strip.empty?)

    number = Float(value)
    number.finite? ? number : nil
  rescue ArgumentError, TypeError
    nil
  end
end
