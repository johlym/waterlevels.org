require "faraday/retry"

module Usbr
  class Client
    BASE_URL = "https://data.usbr.gov/rise/api/".freeze
    ACCEPT = "application/vnd.api+json".freeze
    DEFAULT_ITEMS_PER_PAGE = 100

    Error = Class.new(StandardError)
    NotFoundError = Class.new(Error)
    RateLimitError = Class.new(Error)

    def initialize(connection: nil, request_pause_ms: nil)
      @request_pause_ms = request_pause_ms.nil? ? default_request_pause_ms : request_pause_ms.to_i
      @connection = connection || build_connection
      @first_request = true
    end

    def location(location_id)
      get("location/#{location_id}")
    end

    def catalog_item(item_id)
      get("catalog-item/#{item_id}")
    end

    # Yields each Result attributes hash for a catalog item, newest-first as
    # returned by RISE. Pages with itemsPerPage until exhausted or +after+/+before+
    # date filters bound the window.
    def each_result(item_id, after: nil, before: nil, items_per_page: DEFAULT_ITEMS_PER_PAGE)
      page = 1
      loop do
        body = results(
          item_id: item_id,
          after: after,
          before: before,
          items_per_page: items_per_page,
          page: page
        )
        rows = Array(body["data"])
        break if rows.empty?

        rows.each do |row|
          attrs = row["attributes"] || {}
          yield attrs
        end

        meta = body["meta"] || {}
        total = meta["totalItems"].to_i
        per_page = meta["itemsPerPage"].to_i
        per_page = items_per_page if per_page <= 0
        break if rows.size < per_page
        break if total.positive? && (page * per_page) >= total

        page += 1
      end
    end

    def results(item_id:, after: nil, before: nil, items_per_page: DEFAULT_ITEMS_PER_PAGE, page: 1)
      params = {
        "itemId" => item_id,
        "itemsPerPage" => items_per_page,
        "page" => page
      }
      params["dateTime[after]"] = after if after.present?
      params["dateTime[before]"] = before if before.present?
      get("result", params)
    end

    private

    def get(path, params = {})
      Telemetry.in_span(
        "usbr.http.get",
        attributes: {
          "http.request.method" => "GET",
          "app.operation" => "usbr.http.get",
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
        raise NotFoundError, "USBR RISE not found (#{response.status})"
      when 429
        raise RateLimitError, "USBR RISE rate limited (#{response.status})"
      else
        raise Error, "USBR RISE error #{response.status}: #{response.body.inspect}"
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

      ENV.fetch("USBR_REQUEST_PAUSE_MS", "250").to_i
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
