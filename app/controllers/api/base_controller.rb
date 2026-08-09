module Api
  class BaseController < ApplicationController
    include CacheableResponse

    before_action :ensure_first_party_api_request!

    private

    def ensure_first_party_api_request!
      return if FirstPartyApiRequest.allowed?(request)

      head :forbidden
    end
  end
end
