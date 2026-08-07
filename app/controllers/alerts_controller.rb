class AlertsController < ApplicationController
  include CacheableResponse

  def show
    @listing = AlertsListingCache.fetch
    Telemetry.add_attributes(
      "app.page" => "alerts",
      "app.operation" => "page.alerts",
      "app.station_count" => @listing[:total_count] || @listing["total_count"] ||
        Array(@listing[:locations] || @listing["locations"]).size
    )
    cache_public!(tags: [ "alerts" ])
  end
end
