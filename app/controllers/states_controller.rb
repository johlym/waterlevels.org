class StatesController < ApplicationController
  include CacheableResponse

  def show
    @state_code = params[:state].to_s.downcase
    raise ActiveRecord::RecordNotFound unless @state_code.match?(/\A[a-z]{2}\z/)

    @listing = StateListingCache.fetch(@state_code)
    Telemetry.add_attributes(
      "app.page" => "state",
      "app.operation" => "page.state",
      "app.state" => @state_code,
      "app.station_count" => @listing[:total_count] || @listing["total_count"] ||
        Array(@listing[:locations] || @listing["locations"]).size
    )
    cache_public!(tags: [ "state:#{@state_code}" ])
  end
end
