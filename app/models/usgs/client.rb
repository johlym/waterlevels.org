require "faraday/retry"

module Usgs
  class Client
    BASE_URL = "https://api.waterdata.usgs.gov/ogcapi/v0".freeze
    DEFAULT_LIMIT = 1000

    Error = Class.new(StandardError)
    RateLimitError = Class.new(Error)

    def initialize(api_key: ENV["USGS_API_KEY"], connection: nil)
      @api_key = api_key
      @connection = connection || build_connection
    end

    def each_collection_item(collection, params = {})
      next_url = nil
      query = params.merge(limit: params[:limit] || DEFAULT_LIMIT, f: "json")

      loop do
        body = if next_url
          get_absolute(next_url)
        else
          get("/collections/#{collection}/items", query)
        end

        Array(body["features"] || body["items"]).each { |feature| yield normalize_feature(feature) }

        next_url = link_href(body, "next")
        break if next_url.blank?
      end
    end

    def get(path, params = {})
      response = @connection.get(path) do |req|
        req.params.update(params)
        req.headers["X-Api-Key"] = @api_key if @api_key.present?
      end
      handle_response(response)
    end

    def get_absolute(url)
      response = @connection.get(url) do |req|
        req.headers["X-Api-Key"] = @api_key if @api_key.present?
      end
      handle_response(response)
    end

    private

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :retry, max: 3, interval: 1, retry_statuses: [ 429, 500, 502, 503, 504 ]
        f.options.timeout = 60
        f.options.open_timeout = 10
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      if response.status == 429
        raise RateLimitError, "USGS rate limited"
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
