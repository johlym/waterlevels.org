require "faraday/retry"

module Nldi
  class Client
    # Trailing slash matters: Faraday treats paths that start with "/" as
    # host-absolute and would drop "/nldi/" from the base URL.
    BASE_URL = "https://api.water.usgs.gov/nldi/".freeze

    Error = Class.new(StandardError)

    def initialize(connection: nil, request_pause_ms: nil)
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
      @first_request = true
    end

    def navigate_sites(usgs_id, mode:, distance_km:)
      get_features(
        "linked-data/nwissite/#{usgs_id}/navigation/#{mode}/nwissite",
        f: "json",
        distance: distance_km,
        excludeGeometry: true
      )
    end

    def navigate_flowlines(usgs_id, mode:, distance_km:)
      get_features(
        "linked-data/nwissite/#{usgs_id}/navigation/#{mode}/flowlines",
        f: "json",
        distance: distance_km,
        trimStart: true
      )
    end

    private

    def get_features(path, params)
      Telemetry.in_span(
        "nldi.http.get",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "nldi.http.get",
          "app.path" => path
        }
      ) do
        pause_between_requests!
        response = @connection.get(path) do |req|
          req.params.update(stringify_params(params))
          req.headers["Accept"] = "application/geo+json, application/json"
        end
        Telemetry.add_attributes(
          "http.response.status_code" => response.status,
          "app.found" => response.status != 404
        )
        return [] if response.status == 404

        body = handle_response(response)
        Array(body["features"])
      end
    end

    def default_request_pause_ms
      return 0 if Rails.env.test?

      AppConfig.integer(:nldi_request_pause_ms)
    end

    def pause_between_requests!
      if @first_request
        @first_request = false
        return
      end
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
      unless response.success?
        raise Error, "NLDI #{response.status}: #{response.body}"
      end

      response.body.is_a?(Hash) ? response.body : {}
    end
  end
end
