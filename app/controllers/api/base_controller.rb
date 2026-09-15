module Api
  class BaseController < ApplicationController
    include CacheableResponse

    RATE_LIMIT_TO = 120
    RATE_LIMIT_WITHIN = 1.minute
    RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

    before_action :ensure_first_party_api_request!
    rate_limit to: RATE_LIMIT_TO,
               within: RATE_LIMIT_WITHIN,
               by: -> { request.remote_ip },
               store: (Rails.env.test? ? RATE_LIMIT_STORE : Rails.cache)

    private

    def ensure_first_party_api_request!
      return if FirstPartyApiRequest.allowed?(request)

      head :forbidden
    end
  end
end
