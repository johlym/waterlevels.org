class MapsController < ApplicationController
  include CacheableResponse

  def show
    Telemetry.add_attributes("app.page" => "map", "app.operation" => "page.map")
    cache_public!(tags: [ "map" ])
  end
end
