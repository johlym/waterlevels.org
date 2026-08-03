class AlertsController < ApplicationController
  include CacheableResponse

  def show
    @listing = AlertsListingCache.fetch
    cache_public!(tags: [ "alerts" ])
  end
end
