module WellKnown
  class ApiCatalogController < ApplicationController
    include CacheableResponse

    def show
      cache_static_page!
      response.set_header("Link", ApiCatalog::SELF_LINK)
      render json: ApiCatalog.linkset(base_url: catalog_base_url),
             content_type: ApiCatalog::CONTENT_TYPE
    end

    private

    def catalog_base_url
      if !Rails.env.local? && ENV["APP_HOST"].present?
        "https://#{ENV["APP_HOST"]}"
      else
        request.base_url
      end
    end
  end
end
