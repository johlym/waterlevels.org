module Cloudflare
  class CachePurge
    BASE_URL = "https://api.cloudflare.com/client/v4/".freeze
    TAGS_PER_REQUEST = 100

    Error = Class.new(StandardError)

    def initialize(api_token: ENV["CLOUDFLARE_API_TOKEN"], zone_id: ENV["CLOUDFLARE_ZONE_ID"], connection: nil)
      @api_token = api_token.to_s.presence
      @zone_id = zone_id.to_s.presence
      @connection = connection || build_connection
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

      list.each_slice(TAGS_PER_REQUEST) do |batch|
        request_purge(tags: batch)
      end
      :purged
    end

    private

    def request_purge(body)
      response = @connection.post("zones/#{@zone_id}/purge_cache") do |req|
        req.headers["Authorization"] = "Bearer #{@api_token}"
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
        req.options.timeout = 15
      end

      payload = parse_body(response.body)
      return if response.success? && payload["success"] != false

      message = Array(payload["errors"]).map { |error| error["message"] || error.to_s }.join("; ")
      message = "HTTP #{response.status}" if message.blank?
      raise Error, "Cloudflare purge failed: #{message}"
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
