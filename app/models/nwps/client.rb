require "faraday/retry"

module Nwps
  class Client
    BASE_URL = "https://api.water.noaa.gov/nwps/v1/".freeze
    LIST_TIMEOUT_SECONDS = 90
    # NWPS publishes ~10 requests / 5 minutes. Default to 30s between calls so
    # a 10-slice list pass stays inside that budget.
    DEFAULT_REQUEST_PAUSE_MS = 30_000

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
      Telemetry.in_span(
        "nwps.http.gauge",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "nwps.http.gauge",
          "app.nwps_identifier" => identifier.to_s
        }
      ) do
        pause_between_requests!
        response = @connection.get("gauges/#{identifier}") do |req|
          req.headers["Accept"] = "application/json"
        end
        Telemetry.add_attributes(
          "http.response.status_code" => response.status,
          "app.found" => response.status != 404
        )
        return nil if response.status == 404

        handle_response(response)
      end
    end

    # Returns the NWPS gauge list for one geographic slice (status + LID; no
    # usgsId / thresholds). +region+ is required so callers cannot request the
    # unbounded national payload that NWPS often 504s on.
    def gauges(region:)
      region_id = region.to_s
      bbox = ListRegions.bbox_for(region_id)

      Telemetry.in_span(
        "nwps.http.gauges",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "nwps.http.gauges",
          "app.nwps_region" => region_id
        }
      ) do
        pause_between_requests!
        response = @connection.get("gauges") do |req|
          req.headers["Accept"] = "application/json"
          req.options.timeout = LIST_TIMEOUT_SECONDS
          req.params["bbox.xmin"] = bbox.fetch(:xmin)
          req.params["bbox.ymin"] = bbox.fetch(:ymin)
          req.params["bbox.xmax"] = bbox.fetch(:xmax)
          req.params["bbox.ymax"] = bbox.fetch(:ymax)
          req.params["srid"] = "EPSG_4326"
        end
        body = handle_response(response)
        gauges = Array(body["gauges"])
        Telemetry.add_attributes(
          "http.response.status_code" => response.status,
          "app.batch_size" => gauges.size,
          "app.locations_count" => gauges.size
        )
        gauges
      end
    end

    private

    def default_request_pause_ms
      return 0 if Rails.env.test?

      ENV.fetch("NWPS_REQUEST_PAUSE_MS", DEFAULT_REQUEST_PAUSE_MS.to_s).to_i
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
          # Do not retry 429 — NWPS budget is tiny and retries make it worse.
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
