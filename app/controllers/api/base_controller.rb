module Api
  class BaseController < ApplicationController
    include CacheableResponse

    before_action :ensure_first_party_api_request!
    after_action :set_first_party_api_vary_header

    private

    def ensure_first_party_api_request!
      return if FirstPartyApiRequest.allowed?(request)

      head :forbidden
    end

    # Segment CDN variants when Cloudflare Cache Rules honor Vary / include
    # these headers in the custom cache key for `/api/*`.
    def set_first_party_api_vary_header
      existing = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:blank?)
      response.headers["Vary"] = (
        existing + [ FirstPartyApiRequest::CLIENT_HEADER, "Sec-Fetch-Site" ]
      ).uniq.join(", ")
    end
  end
end
