module Api
  module Map
    class StationsController < ApplicationController
      include CacheableResponse

      def index
        west, south, east, north = bbox_params
        stations = MonitoringLocation.in_bbox(west, south, east, north).limit(2000).map do |loc|
          {
            id: loc.site_number,
            name: loc.name,
            lat: loc.latitude.to_f,
            lon: loc.longitude.to_f,
            state: loc.state_code,
            path: "/gauges/#{loc.path_state}/#{loc.to_param}",
            stale: loc.stale?,
            has_water_level: loc.has_water_level,
            has_discharge: loc.has_discharge,
            has_temperature: loc.has_temperature,
            water_level: loc.latest_water_level_value&.to_f,
            water_level_unit: UnitLabel.format(loc.latest_water_level_unit),
            water_level_parameter_code: loc.latest_water_level_parameter_code,
            water_level_label: Usgs::ParameterCodes.label_for(loc.latest_water_level_parameter_code, fallback: "Water level"),
            discharge: loc.latest_discharge_value&.to_f,
            discharge_unit: UnitLabel.format(loc.latest_discharge_unit),
            temperature_c: loc.latest_temperature_c&.to_f,
            observed_at: loc.latest_observed_at&.iso8601,
            time_zone: loc.time_zone,
            time_zone_identifier: loc.time_zone_identifier,
            approval_status: loc.latest_approval_status
          }
        end

        cache_public!(max_age: 30, s_maxage: 300, tags: [ "map-stations" ])
        render json: { stations: stations }
      end

      private

      def bbox_params
        bbox = params.require(:bbox).split(",").map(&:to_f)
        raise ActionController::BadRequest, "bbox must be west,south,east,north" unless bbox.length == 4

        bbox
      end
    end
  end
end
