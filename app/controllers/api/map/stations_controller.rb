module Api
  module Map
    class StationsController < ApplicationController
      include CacheableResponse

      SEARCH_LIMIT = 8
      SEARCH_MIN_LENGTH = 2

      def index
        west, south, east, north = bbox_params
        stations = MonitoringLocation.in_bbox(west, south, east, north).limit(2000).map do |loc|
          station_payload(loc)
        end

        cache_public!(max_age: 30, s_maxage: 300, tags: [ "map-stations" ])
        render json: { stations: stations }
      end

      def search
        query = params[:q].to_s.strip
        stations =
          if query.length < SEARCH_MIN_LENGTH
            []
          else
            MonitoringLocation.search(query).limit(SEARCH_LIMIT).map { |loc| search_payload(loc) }
          end

        cache_public!(max_age: 30, s_maxage: 300, tags: [ "map-station-search" ])
        render json: { stations: stations }
      end

      def nearest
        lat = params.require(:lat)
        lon = params.require(:lon)
        location = NearbyStations.nearest_to(lat, lon)

        cache_public!(max_age: 30, s_maxage: 120, tags: [ "map-station-nearest" ])
        if location
          render json: { station: search_payload(location) }
        else
          render json: { station: nil }, status: :not_found
        end
      end

      private

      def bbox_params
        bbox = params.require(:bbox).split(",").map(&:to_f)
        raise ActionController::BadRequest, "bbox must be west,south,east,north" unless bbox.length == 4

        bbox
      end

      def station_payload(loc)
        search_payload(loc).merge(
          lat: loc.latitude.to_f,
          lon: loc.longitude.to_f,
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
          approval_status: loc.latest_approval_status,
          flood_stage_action: loc.flood_stage_action&.to_f,
          flood_stage_minor: loc.flood_stage_minor&.to_f,
          flood_stage_moderate: loc.flood_stage_moderate&.to_f,
          flood_stage_major: loc.flood_stage_major&.to_f
        )
      end

      def search_payload(loc)
        {
          id: loc.site_number,
          name: loc.display_name,
          state: loc.state_code,
          path: "/gauges/#{loc.path_state}/#{loc.to_param}",
          stale: loc.stale?,
          has_water_level: loc.has_water_level,
          has_discharge: loc.has_discharge,
          has_temperature: loc.has_temperature,
          nwps_matched: loc.nwps_matched,
          flood_category: loc.flood_category,
          flood_category_label: loc.flood_category_short_label,
          flood_alert: loc.flood_alert?
        }
      end
    end
  end
end
