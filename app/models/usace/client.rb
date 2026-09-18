require "faraday/retry"

module Usace
  # CWMS Data API (CDA) client for curated Corps projects.
  # Docs: https://cwms-data.usace.army.mil/cwms-data/swagger-ui.html
  class Client
    BASE_URL = "https://cwms-data.usace.army.mil/cwms-data/".freeze
    ACCEPT = "application/json".freeze
    DEFAULT_PAGE_SIZE = 500

    Error = Class.new(StandardError)
    NotFoundError = Class.new(Error)
    RateLimitError = Class.new(Error)

    def initialize(connection: nil, request_pause_ms: nil)
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
      @first_request = true
    end

    def location(name:, office:)
      get("locations/#{name}", { "office" => office, "format" => "json" })
    end

    # Yields each [Time(utc), value(Float), quality] row for a named timeseries,
    # oldest-first as returned by CDA. Pages with +page+ until exhausted.
    def each_timeseries_value(name:, office:, begin_at:, end_at:, unit: "ft", page_size: DEFAULT_PAGE_SIZE)
      page = nil
      loop do
        body = timeseries(
          name: name,
          office: office,
          begin_at: begin_at,
          end_at: end_at,
          unit: unit,
          page_size: page_size,
          page: page
        )
        Array(body["values"]).each do |row|
          next unless row.is_a?(Array) && row.size >= 2
          next if row[1].nil?

          observed_at = Time.zone.at(row[0].to_i / 1000.0).utc
          yield observed_at, row[1].to_f, row[2]
        end

        page = body["next-page"].presence
        break if page.blank?
      end
    end

    def timeseries(name:, office:, begin_at:, end_at:, unit: "ft", page_size: DEFAULT_PAGE_SIZE, page: nil)
      params = {
        "name" => name,
        "office" => office,
        "begin" => iso8601(begin_at),
        "end" => iso8601(end_at),
        "unit" => unit,
        "format" => "json",
        "page-size" => page_size
      }
      params["page"] = page if page.present?
      get("timeseries", params)
    end

    private

    def iso8601(time)
      time = Time.zone.parse(time.to_s) unless time.respond_to?(:utc)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def get(path, params = {})
      Telemetry.in_span(
        "usace.http.get",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "usace.http.get",
          "app.path" => path
        }
      ) do
        pause_between_requests!
        response = @connection.get(path) do |req|
          req.headers["Accept"] = ACCEPT
          params.each { |key, value| req.params[key.to_s] = value }
        end
        Telemetry.add_attributes("http.response.status_code" => response.status)
        handle_response(response)
      end
    end

    def handle_response(response)
      case response.status
      when 200..299
        response.body
      when 404
        raise NotFoundError, "USACE CWMS not found (#{response.status})"
      when 429
        raise RateLimitError, "USACE CWMS rate limited (#{response.status})"
      else
        raise Error, "USACE CWMS error #{response.status}: #{response.body.inspect}"
      end
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :retry, max: 2, interval: 0.5, interval_randomness: 0.2,
          backoff_factor: 2, exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ],
          retry_statuses: [ 500, 502, 503, 504 ]
        f.options.timeout = 60
        f.options.open_timeout = 10
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    def default_request_pause_ms
      return 0 if Rails.env.test?

      ENV.fetch("USACE_REQUEST_PAUSE_MS", "250").to_i
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
