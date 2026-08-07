require "faraday/retry"

# Resolves US ZIP codes to a map-ready centroid via Zippopotam.us.
class ZipCodeLookup
  BASE_URL = "https://api.zippopotam.us/".freeze
  ZIP_PATTERN = /\A(\d{5})(?:-?\d{4})?\z/
  CACHE_TTL = 30.days
  DEFAULT_ZOOM = 12

  Error = Class.new(StandardError)

  Result = Data.define(:zip, :latitude, :longitude, :place_name, :state_code, :state_name, :zoom) do
    def map_path
      "/map?lat=#{latitude}&lon=#{longitude}&zoom=#{zoom}"
    end

    def display_name
      if place_name.present? && state_code.present?
        "#{zip} — #{place_name}, #{state_code}"
      else
        zip
      end
    end
  end

  def self.extract_zip(query)
    match = query.to_s.strip.match(ZIP_PATTERN)
    match && match[1]
  end

  def self.lookup(query, connection: nil)
    new(connection: connection).lookup(query)
  end

  def initialize(connection: nil)
    @connection = connection || build_connection
  end

  def lookup(query)
    zip = self.class.extract_zip(query)
    return nil if zip.blank?

    Telemetry.in_span(
      "zippopotam.lookup",
      attributes: { "zip.code" => zip }
    ) do
      cached = Rails.cache.read(cache_key(zip))
      if cached
        Telemetry.add_attributes("cache.hit" => true)
        cached
      else
        Telemetry.add_attributes("cache.hit" => false)
        result = fetch_zip(zip)
        Rails.cache.write(cache_key(zip), result, expires_in: CACHE_TTL)
        result
      end
    rescue Error, Faraday::Error, Faraday::TimeoutError => e
      Telemetry.record_exception(e, slug: "err-zippopotam-lookup")
      Rails.logger.warn("[ZipCodeLookup] #{zip}: #{e.class}: #{e.message}")
      nil
    end
  end

  private

  def cache_key(zip)
    "zip_code_lookup:us:#{zip}"
  end

  def fetch_zip(zip)
    response = @connection.get("us/#{zip}") do |req|
      req.headers["Accept"] = "application/json"
    end
    Telemetry.add_attributes("http.response.status_code" => response.status)
    return nil if response.status == 404

    unless response.success?
      raise Error, "Zippopotam #{response.status}: #{response.body}"
    end

    body = response.body.is_a?(Hash) ? response.body : {}
    place = Array(body["places"]).first
    return nil if place.blank?

    lat = place["latitude"].to_f
    lon = place["longitude"].to_f
    return nil unless lat.between?(-90, 90) && lon.between?(-180, 180)

    Result.new(
      zip: body["post code"].presence || zip,
      latitude: lat,
      longitude: lon,
      place_name: place["place name"].to_s,
      state_code: place["state abbreviation"].to_s.upcase,
      state_name: place["state"].to_s,
      zoom: DEFAULT_ZOOM
    )
  end

  def build_connection
    Faraday.new(url: BASE_URL) do |f|
      f.request :retry,
        max: 2,
        interval: 0.25,
        interval_randomness: 0.5,
        backoff_factor: 2,
        max_interval: 2,
        retry_statuses: [ 500, 502, 503, 504 ]
      f.options.timeout = 5
      f.options.open_timeout = 3
      f.response :json, content_type: /\bjson$/
      f.adapter Faraday.default_adapter
    end
  end
end
