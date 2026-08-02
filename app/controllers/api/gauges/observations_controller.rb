module Api
  module Gauges
    class ObservationsController < ApplicationController
      include CacheableResponse

      def index
        location = MonitoringLocation.find_by!(site_number: params[:gauge_id])
        kind = params[:kind].presence || location.measurement_kinds.first
        range = params[:range].presence || "7d"
        range = "7d" unless HydrographSeries::RANGES.key?(range)

        payload = HydrographSeries.for(location: location, kind: kind, range: range)
        cache_public!(tags: ["gauge:#{location.site_number}"])
        render json: payload
      end
    end
  end
end
