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

  def related_station_watch?(category)
    FLOOD_WATCH_CATEGORIES.include?(category.to_s)
  end

  def related_station_readings(node)
    readings = Array(node[:measurements] || node["measurements"])
    return readings if readings.any?

    primary = node[:primary] || node["primary"]
    primary.present? ? [ primary ] : []
  end

  def nearest_stream_neighbor(nodes)
    Array(nodes).first
  end
end
