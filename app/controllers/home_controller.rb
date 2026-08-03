class HomeController < ApplicationController
  include CacheableResponse

  def show
    @stats = SiteStats.snapshot
    @popular_regions = PopularWaterways.regions
    cache_public!(max_age: 60, s_maxage: 300, tags: [ "home" ])
  end
end
