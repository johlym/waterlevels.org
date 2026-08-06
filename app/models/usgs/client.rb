require "faraday/retry"

module Usgs
  class Client
    # Trailing slash matters: Faraday treats paths that start with "/" as
    # host-absolute and would drop "/ogcapi/v0" from the base URL.
    BASE_URL = "https://api.waterdata.usgs.gov/ogcapi/v0/".freeze
    DEFAULT_LIMIT = 1000

    Error = Class.new(StandardError)
    RateLimitError = Class.new(Error)

    def self.for_tip
      new(api_key: ENV["USGS_API_KEY"], circuit_key: RateLimitCircuit::TIP_KEY)
    end

    def self.for_history
      entry = HistoryKeyPool.claim!
      new(api_key: entry[:api_key], circuit_key: entry[:circuit_key])
    end

    def initialize(api_key: ENV["USGS_API_KEY"], connection: nil, request_pause_ms: nil, circuit_key: RateLimitCircuit::TIP_KEY)
      @api_key = api_key
      @circuit_key = circuit_key.presence || RateLimitCircuit::TIP_KEY
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
    end

    attr_reader :circuit_key

    def each_collection_item(collection, params = {})
      next_url = nil
      query = params.merge(limit: params[:limit] || DEFAULT_LIMIT, f: "json")
      first_page = true

      loop do
        pause_between_requests! unless first_page
        first_page = false

        body = if next_url
          get_absolute(next_url)
        else
          get("collections/#{collection}/items", query)
        end

        Array(body["features"] || body["items"]).each { |feature| yield normalize_feature(feature) }

        next_url = link_href(body, "next")
        break if next_url.blank?
      end
    end

    def get(path, params = {})
      raise_if_circuit_open!
      response = @connection.get(path) do |req|
        req.params.update(stringify_params(params))
        req.headers["Accept"] = "application/geo+json, application/json"
        req.headers["X-Api-Key"] = @api_key if @api_key.present?
      end
      handle_response(response)
    end

    def get_absolute(url)
      raise_if_circuit_open!
      response = @connection.get(url) do |req|
        req.headers["Accept"] = "application/geo+json, application/json"
        req.headers["X-Api-Key"] = @api_key if @api_key.present?
      end
      handle_response(response)
    end

    private

    def raise_if_circuit_open!
      return unless RateLimitCircuit.open?(@circuit_key)

      raise RateLimitError, "USGS rate limit circuit open key=#{@circuit_key}"
    end

    def default_request_pause_ms
      return 0 if Rails.env.test?

      ENV.fetch("USGS_REQUEST_PAUSE_MS", "100").to_i
    end

    def pause_between_requests!
      return if @request_pause_ms <= 0

      sleep_pause(@request_pause_ms / 1000.0)
    end

    def sleep_pause(seconds)
      sleep(seconds)
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :retry,
          max: 5,
          interval: 1,
          interval_randomness: 0.5,
          backoff_factor: 2,
          max_interval: 60,
          # Do not retry 429 — that burns the remaining hourly budget and feeds job backlogs.
          retry_statuses: [ 500, 502, 503, 504 ]
        f.options.timeout = 60
        f.options.open_timeout = 10
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    def stringify_params(params)
      params.transform_keys(&:to_s).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
    end

    def handle_response(response)
      if response.status == 429
        RateLimitCircuit.open!(key_id: @circuit_key)
        raise RateLimitError, "USGS rate limited key=#{@circuit_key}"
      end
      unless response.success?
        raise Error, "USGS #{response.status}: #{response.body}"
      end
      response.body.is_a?(Hash) ? response.body : {}
    end

    def normalize_feature(feature)
      props = feature["properties"] || feature
      geometry = feature["geometry"]
      coords = geometry && geometry["coordinates"]
      props.merge(
        "id" => feature["id"] || props["id"],
        "longitude" => coords && coords[0],
        "latitude" => coords && coords[1]
      )
    end

    def link_href(body, rel)
      links = body["links"] || []
      link = links.find { |l| l["rel"] == rel }
      link && link["href"]
    end
  end
end
