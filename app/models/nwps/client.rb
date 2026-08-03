require "faraday/retry"

module Nwps
  class Client
    BASE_URL = "https://api.water.noaa.gov/nwps/v1/".freeze
    LIST_TIMEOUT_SECONDS = 90

    Error = Class.new(StandardError)
    NotFoundError = Class.new(Error)

    def initialize(connection: nil, request_pause_ms: nil)
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
      @first_request = true
    end

    # Returns gauge Hash or nil when NWPS has no point for this identifier
    # (USGS site number or NWS LID).
    def gauge(identifier)
      pause_between_requests!
      response = @connection.get("gauges/#{identifier}") do |req|
        req.headers["Accept"] = "application/json"
      end
      return nil if response.status == 404

      handle_response(response)
    end

    # Returns the national NWPS gauge list (status + LID; no usgsId / thresholds).
    # Optional bbox hash: { xmin:, ymin:, xmax:, ymax:, srid: "EPSG_4326" }.
    def gauges(bbox: nil)
      pause_between_requests!
      response = @connection.get("gauges") do |req|
        req.headers["Accept"] = "application/json"
        req.options.timeout = LIST_TIMEOUT_SECONDS
        if bbox
          req.params["bbox.xmin"] = bbox[:xmin]
          req.params["bbox.ymin"] = bbox[:ymin]
          req.params["bbox.xmax"] = bbox[:xmax]
          req.params["bbox.ymax"] = bbox[:ymax]
          req.params["srid"] = bbox[:srid] || "EPSG_4326"
        end
      end
      body = handle_response(response)
      Array(body["gauges"])
    end

    private

    def default_request_pause_ms
      return 0 if Rails.env.test?

      ENV.fetch("NWPS_REQUEST_PAUSE_MS", "100").to_i
    end

    def pause_between_requests!
      if @first_request
        @first_request = false
        return
      end
      return if @request_pause_ms <= 0

      sleep(@request_pause_ms / 1000.0)
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :retry,
          max: 4,
          interval: 1,
          interval_randomness: 0.5,
          backoff_factor: 2,
          max_interval: 30,
          retry_statuses: [ 500, 502, 503, 504 ]
        f.options.timeout = 30
        f.options.open_timeout = 10
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      unless response.success?
        raise Error, "NWPS #{response.status}: #{response.body}"
      end
      response.body.is_a?(Hash) ? response.body : {}
    end
  end
end
