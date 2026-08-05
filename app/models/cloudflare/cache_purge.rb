module Cloudflare
  class CachePurge
    BASE_URL = "https://api.cloudflare.com/client/v4/".freeze
    TAGS_PER_REQUEST = 100
    MAX_ATTEMPTS = 4
    # Free plans allow ~5 tag-purge requests/minute; back off in that ballpark.
    BASE_BACKOFF = 15

    Error = Class.new(StandardError)
    RateLimited = Class.new(Error)

    def initialize(api_token: ENV["CLOUDFLARE_API_TOKEN"], zone_id: ENV["CLOUDFLARE_ZONE_ID"], connection: nil, sleeper: nil)
      @api_token = api_token.to_s.presence
      @zone_id = zone_id.to_s.presence
      @connection = connection || build_connection
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def enabled?
      @api_token.present? && @zone_id.present?
    end

    # Purges edge objects associated with the given Cache-Tag values.
    # No-ops when credentials are unset (local/dev/test).
    def purge_tags(tags)
      list = Array(tags).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      return :empty if list.empty?
      return :skipped unless enabled?

      list.each_slice(TAGS_PER_REQUEST).with_index do |batch, index|
        @sleeper.call(1) if index.positive?
        request_purge(tags: batch)
      end
      :purged
    end

    private

    def request_purge(body)
      attempts = 0
      begin
        attempts += 1
        response = @connection.post("zones/#{@zone_id}/purge_cache") do |req|
          req.headers["Authorization"] = "Bearer #{@api_token}"
          req.headers["Content-Type"] = "application/json"
          req.body = body.to_json
          req.options.timeout = 15
        end

        payload = parse_body(response.body)
        return if response.success? && payload["success"] != false

        message = error_message(response, payload)
        raise RateLimited, message if rate_limited?(response, payload, message)

        raise Error, "Cloudflare purge failed: #{message}"
      rescue RateLimited
        raise if attempts >= MAX_ATTEMPTS

        @sleeper.call(BASE_BACKOFF * attempts)
        retry
      end
    end

    def rate_limited?(response, payload, message)
      return true if response.status == 429

      codes = Array(payload["errors"]).filter_map { |error| error.is_a?(Hash) ? error["code"] : nil }
      return true if codes.any? { |code| code.to_i == 429 }

      message.to_s.match?(/rate limit/i)
    end

    def error_message(response, payload)
      message = Array(payload["errors"]).map { |error| error["message"] || error.to_s }.join("; ")
      message = "HTTP #{response.status}" if message.blank?
      message
    end

    def parse_body(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.adapter Faraday.default_adapter
      end
    end
  end
end
