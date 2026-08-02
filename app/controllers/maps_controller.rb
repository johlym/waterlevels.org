class MapsController < ApplicationController
  include CacheableResponse

  def show
    cache_public!(tags: [ "map" ])
  end
end
