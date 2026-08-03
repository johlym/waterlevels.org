class AlertsListingCache
  PREFIX = "alerts_listing:v1".freeze
  TTL = 6.hours
  CACHE_KEY = PREFIX

  SEVERITY_ORDER_SQL = <<~SQL.squish.freeze
    CASE flood_category
      WHEN 'major' THEN 0
      WHEN 'moderate' THEN 1
      WHEN 'minor' THEN 2
      WHEN 'action' THEN 3
      ELSE 4
    END
  SQL

  def self.read
    Rails.cache.read(CACHE_KEY)
  end

  def self.warm
    rows = MonitoringLocation.flood_alert
      .order(Arel.sql("LOWER(state_code) ASC, #{SEVERITY_ORDER_SQL}, LOWER(display_name) ASC"))
      .map { |loc| StateListingCache.serialize_location(loc) }

    payload = {
      locations: rows,
      total_count: rows.size,
      state_count: rows.map { |row| row[:state_code] }.uniq.size,
      major_count: rows.count { |row| row[:flood_category] == "major" },
      offline_count: rows.count { |row| row[:stale] }
    }
    Rails.cache.write(CACHE_KEY, payload, expires_in: TTL)
    payload
  end

  def self.fetch
    cached = read
    return warm if cached.blank?
    return warm unless cached.is_a?(Hash)
    return warm unless cached.key?(:total_count) || cached.key?("total_count")
    return warm unless cached.key?(:state_count) || cached.key?("state_count")

    cached
  end
end
