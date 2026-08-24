# Redis-backed cache for first-party `/api/*` JSON payloads.
# Uses generation counters so syncs can invalidate whole namespaces without
# delete_matched. HTTP responses stay private/no-store (not edge-cached).
class ApiResponseCache
  PREFIX = "api_response:v1".freeze
  GENERATION_TTL = 7.days

  MAP_NAMESPACES = {
    "map-stations" => 5.minutes,
    "map-station-search" => 5.minutes,
    "map-station-nearest" => 2.minutes
  }.freeze

  OBSERVATIONS_TTL = 1.hour
  OBSERVATIONS_NAMESPACE = "gauge-observations".freeze

  def self.fetch_map_stations(bbox)
    fetch("map-stations", bbox) { yield }
  end

  def self.fetch_map_search(query)
    fetch("map-station-search", query.to_s.downcase) { yield }
  end

  def self.fetch_map_nearest(lat, lon)
    fetch("map-station-nearest", lat, lon) { yield }
  end

  def self.fetch_observations(site_number:, parameter_code:, kind:, range:)
    key = cache_key(
      OBSERVATIONS_NAMESPACE,
      generation(OBSERVATIONS_NAMESPACE),
      generation("#{OBSERVATIONS_NAMESPACE}:#{site_number}"),
      site_number,
      parameter_code,
      kind,
      range
    )
    cached = Rails.cache.read(key)
    return cached if cached

    payload = yield
    # Empty hydrographs are often a transient catalog/selection miss. Do not
    # pin that 200 for an hour while tip cards still show current values.
    unless empty_observations?(payload)
      Rails.cache.write(key, payload, expires_in: OBSERVATIONS_TTL)
    end
    payload
  end

  def self.empty_observations?(payload)
    return true if payload.blank?

    points = payload.is_a?(Hash) ? (payload[:points] || payload["points"]) : nil
    Array(points).empty?
  end
  private_class_method :empty_observations?

  def self.invalidate_map!
    MAP_NAMESPACES.each_key { |namespace| bump!(namespace) }
  end

  def self.invalidate_all_observations!
    bump!(OBSERVATIONS_NAMESPACE)
  end

  def self.invalidate_observations!(site_number)
    return if site_number.blank?

    bump!("#{OBSERVATIONS_NAMESPACE}:#{site_number}")
  end

  def self.invalidate_after_sync!
    invalidate_map!
    invalidate_all_observations!
  end

  def self.fetch(namespace, *parts)
    ttl = MAP_NAMESPACES.fetch(namespace.to_s)
    key = cache_key(namespace, generation(namespace), *parts)
    Rails.cache.fetch(key, expires_in: ttl) { yield }
  end
  private_class_method :fetch

  def self.cache_key(*parts)
    ([ PREFIX ] + parts.map { |part| normalize(part) }).join("/")
  end
  private_class_method :cache_key

  def self.normalize(value)
    value.to_s.strip.gsub(%r{[^a-zA-Z0-9._-]+}, "_").presence || "-"
  end
  private_class_method :normalize

  def self.generation(scope)
    Rails.cache.read(generation_key(scope)).presence || "0"
  end
  private_class_method :generation

  def self.bump!(scope)
    current = generation(scope).to_i
    Rails.cache.write(generation_key(scope), (current + 1).to_s, expires_in: GENERATION_TTL)
  end
  private_class_method :bump!

  def self.generation_key(scope)
    "#{PREFIX}/gen/#{normalize(scope)}"
  end
  private_class_method :generation_key
end
