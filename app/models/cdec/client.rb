require "faraday/retry"
require "json"

module Cdec
  # California Data Exchange Center daily sensor client.
  # JSONDataServlet returns text/plain JSON (not application/json).
  class Client
    BASE_URL = "https://cdec.water.ca.gov/".freeze
    READINGS_PATH = "dynamicapp/req/JSONDataServlet".freeze
    MISSING_VALUE = -999

    Error = Class.new(StandardError)
    NotFoundError = Class.new(Error)
    RateLimitError = Class.new(Error)

    def initialize(connection: nil, request_pause_ms: nil)
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
      @first_request = true
    end

    # Yields each raw reading hash for a station/sensor/duration window.
    def each_reading(station_id:, sensor_num:, start_on:, end_on:, dur_code: "D")
      rows = readings(
        station_id: station_id,
        sensor_num: sensor_num,
        start_on: start_on,
        end_on: end_on,
        dur_code: dur_code
      )
      Array(rows).each { |row| yield row if row.is_a?(Hash) }
    end

    def readings(station_id:, sensor_num:, start_on:, end_on:, dur_code: "D")
      get(READINGS_PATH, {
        "Stations" => station_id,
        "SensorNums" => sensor_num,
        "dur_code" => dur_code,
        "Start" => start_on.to_date.iso8601,
        "End" => end_on.to_date.iso8601
      })
    end

    def self.missing_value?(value)
      return true if value.nil?

      text = value.to_s.strip
      return true if text.blank? || text == "---"

      text.to_f <= MISSING_VALUE
    end

    private

    def get(path, params = {})
      Telemetry.in_span(
        "cdec.http.get",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "cdec.http.get",
          "app.path" => path
        }
      ) do
        pause_between_requests!
        response = @connection.get(path) do |req|
          req.headers["Accept"] = "application/json"
          params.each { |key, value| req.params[key.to_s] = value }
        end
        Telemetry.add_attributes("http.response.status_code" => response.status)
        handle_response(response)
      end
    end

    def handle_response(response)
      case response.status
      when 200..299
        parse_body(response.body)
      when 404
        raise NotFoundError, "CDEC not found (#{response.status})"
      when 429
        raise RateLimitError, "CDEC rate limited (#{response.status})"
      else
        raise Error, "CDEC error #{response.status}: #{response.body.inspect}"
      end
    end

    def parse_body(body)
      parsed = body.is_a?(String) ? JSON.parse(body) : body
      parsed = {} if parsed.nil?
      parsed
    rescue JSON::ParserError => e
      raise Error, "CDEC JSON parse error: #{e.message}"
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :retry, max: 2, interval: 0.5, interval_randomness: 0.2,
          backoff_factor: 2, exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ],
          retry_statuses: [ 500, 502, 503, 504 ]
        f.options.timeout = 60
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end

    def default_request_pause_ms
      return 0 if Rails.env.test?

      ENV.fetch("CDEC_REQUEST_PAUSE_MS", "250").to_i
    end

    def pause_between_requests!
      if @first_request
        @first_request = false
        return
      end
      return if @request_pause_ms <= 0

      sleep(@request_pause_ms / 1000.0)
    end
  end
end
