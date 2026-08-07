module Api
  module Map
    class StationsController < ApplicationController
      include CacheableResponse

      SEARCH_LIMIT = 8
      SEARCH_MIN_LENGTH = 2

      def index
        west, south, east, north = bbox_params
        stations = MonitoringLocation
          .in_bbox(west, south, east, north)
          .includes(selected_time_series: :latest_observation)
          .limit(2000)
          .map { |loc| MapStationPayload.build(loc) }

        Telemetry.add_attributes(
          "map.bbox" => "#{west},#{south},#{east},#{north}",
          "map.station_count" => stations.size
        )
        cache_public!(max_age: 30, s_maxage: 300, tags: [ "map-stations" ])
        render json: { stations: stations }
      end

      def search
        query = params[:q].to_s.strip
        results =
          if query.length < SEARCH_MIN_LENGTH
            []
          else
            build_search_results(query)
          end

        Telemetry.add_attributes(
          "map.search.q_length" => query.length,
          "map.search.result_count" => results.size
        )
        cache_public!(max_age: 30, s_maxage: 300, tags: [ "map-station-search" ])
        render json: { stations: results }
      end

      def nearest
        lat = params.require(:lat)
        lon = params.require(:lon)
        location = NearbyStations.nearest_to(lat, lon)

        Telemetry.add_attributes(
          "map.nearest.found" => location.present?,
          "station.site_number" => location&.site_number
        )
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

      def build_search_results(query)
        zip_results = zip_search_payloads(query)
        state_results = state_search_payloads(query)
        used = zip_results.length + state_results.length
        station_limit = [ SEARCH_LIMIT - used, 0 ].max
        station_results = MonitoringLocation.search(query).limit(station_limit).map { |loc| search_payload(loc) }
        zip_results + state_results + station_results
      end

      def zip_search_payloads(query)
        result = ZipCodeLookup.lookup(query)
        return [] unless result

        [ zip_payload(result) ]
      end

      def state_search_payloads(query)
        return [] if MonitoringLocation.exact_search_match(query).exists?

        Usgs::StateCodes.match_query(query).map { |match| state_payload(match) }
      end

      def zip_payload(result)
        {
          id: result.zip,
          name: result.display_name,
          state: result.state_code.downcase,
          path: result.map_path,
          type: "zip",
          stale: false,
          has_water_level: false,
          has_discharge: false,
          has_temperature: false,
          nwps_matched: false,
          flood_category: nil,
          flood_category_label: nil,
          flood_alert: false
        }
      end

      def state_payload(match)
        {
          id: match[:postal],
          name: match[:name],
          state: match[:postal],
          path: "/gauges/#{match[:postal]}",
          type: "state",
          stale: false,
          has_water_level: false,
          has_discharge: false,
          has_temperature: false,
          nwps_matched: false,
          flood_category: nil,
          flood_category_label: nil,
          flood_alert: false
        }
      end

      def search_payload(loc)
        {
          id: loc.site_number,
          name: loc.display_name,
          state: loc.state_code,
          path: "/gauges/#{loc.path_state}/#{loc.to_param}",
          type: "station",
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
