# Standalone from ApplicationController so social crawlers are never
# blocked by allow_browser / modern-browser gates.
class OgImagesController < ActionController::Base
  include CacheableResponse

  def default
    png = OgImage.default_png
    cache_public!(max_age: 300, s_maxage: 86_400, tags: [ "og", "og:default" ])
    send_data png, type: "image/png", disposition: "inline"
  end

  def station
    location = MonitoringLocation.find_by!(site_number: params[:site_number].to_s)
    snapshot = StationSnapshotCache.fetch(location)
    png = OgImage.station_png(snapshot)
    cache_public!(
      max_age: 60,
      s_maxage: 3600,
      tags: [ "og", "og:gauge:#{location.site_number}", "gauge:#{location.site_number}" ]
    )
    send_data png, type: "image/png", disposition: "inline"
  end
end
