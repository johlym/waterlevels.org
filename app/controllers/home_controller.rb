class HomeController < ApplicationController
  include CacheableResponse

  def show
    @stats = SiteStats.snapshot
    @trends = TrendHighlights.fetch
    @popular_regions = PopularWaterways.regions
    # Match other public pages: longer edge TTL + SWR so idle origin boots are rarer.
    cache_public!(max_age: 60, s_maxage: 3600, tags: [ "home" ])
    response.set_header("Link", ApiCatalog.discovery_link_header)
  end
end
