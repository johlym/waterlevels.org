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

    def self.for_history(purpose)
      entry = HistoryKeyPool.claim!(purpose)
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
      Telemetry.in_span(
        "usgs.collection.iterate",
        attributes: {
          "app.operation" => "usgs.collection.iterate",
          "app.collection" => collection,
          "app.circuit_key" => @circuit_key,
          "app.state" => params[:state_code] || params["state_code"],
          "app.parameter_code" => params[:parameter_code] || params["parameter_code"],
          "app.monitoring_location_id" => params[:monitoring_location_id] || params["monitoring_location_id"]
        }
      ) do
        next_url = nil
        query = params.merge(limit: params[:limit] || DEFAULT_LIMIT, f: "json")
        first_page = true
        page_count = 0
        feature_count = 0

        loop do
          pause_between_requests! unless first_page
          first_page = false

          body = if next_url
            get_absolute(next_url)
          else
            get("collections/#{collection}/items", query)
          end

          page_count += 1
          features = Array(body["features"] || body["items"])
          feature_count += features.size
          features.each { |feature| yield normalize_feature(feature) }

          next_url = link_href(body, "next")
          break if next_url.blank?
        end

        Telemetry.add_attributes(
          "app.page_count" => page_count,
          "app.feature_count" => feature_count,
          "app.observation_count" => feature_count,
          "app.batch_size" => feature_count
        )
      end
    end

    def get(path, params = {})
      Telemetry.in_span(
        "usgs.http.get",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "usgs.http.get",
          "app.path" => path,
          "app.circuit_key" => @circuit_key,
          "app.state" => params[:state_code] || params["state_code"],
          "app.parameter_code" => params[:parameter_code] || params["parameter_code"],
          "app.monitoring_location_id" => params[:monitoring_location_id] || params["monitoring_location_id"]
        }
      ) do
        raise_if_circuit_open!
        response = @connection.get(path) do |req|
          req.params.update(stringify_params(params))
          req.headers["Accept"] = "application/geo+json, application/json"
          req.headers["X-Api-Key"] = @api_key if @api_key.present?
        end
        Telemetry.add_attributes("http.response.status_code" => response.status)
        handle_response(response)
      end
    end

    def get_absolute(url)
      Telemetry.in_span(
        "usgs.http.get_absolute",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "usgs.http.get_absolute",
          "url.full" => url.to_s,
          "app.circuit_key" => @circuit_key
        }
      ) do
        raise_if_circuit_open!
        response = @connection.get(url) do |req|
          req.headers["Accept"] = "application/geo+json, application/json"
          req.headers["X-Api-Key"] = @api_key if @api_key.present?
        end
        Telemetry.add_attributes("http.response.status_code" => response.status)
        handle_response(response)
      end
    end

    private

    def raise_if_circuit_open!
      return unless RateLimitCircuit.open?(@circuit_key)

      raise RateLimitError, "USGS rate limit circuit open key=#{@circuit_key}"
    end

    def default_request_pause_ms
      return 0 if Rails.env.test?

      AppConfig.integer(:usgs_request_pause_ms)
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
