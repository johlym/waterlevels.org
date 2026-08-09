module Api
  module Map
    class StationsController < Api::BaseController
      SEARCH_LIMIT = 8
      SEARCH_MIN_LENGTH = 2

      def index
        west, south, east, north = bbox_params
        bbox = "#{west},#{south},#{east},#{north}"
        payload = ApiResponseCache.fetch_map_stations(bbox) do
          stations = MonitoringLocation
            .in_bbox(west, south, east, north)
            .includes(selected_time_series: :latest_observation)
            .limit(2000)
            .map { |loc| MapStationPayload.build(loc) }
          { stations: stations }
        end

        Telemetry.add_attributes(
          "app.operation" => "map.stations.index",
          "app.bbox" => bbox,
          "app.station_count" => Array(payload[:stations] || payload["stations"]).size,
          "app.batch_size" => Array(payload[:stations] || payload["stations"]).size
        )
        cache_private!
        render json: payload
      end

      def search
        query = params[:q].to_s.strip
        payload = ApiResponseCache.fetch_map_search(query) do
          results =
            if query.length < SEARCH_MIN_LENGTH
              []
            else
              build_search_results(query)
            end
          { stations: results }
        end

        Telemetry.add_attributes(
          "app.operation" => "map.stations.search",
          "app.query_length" => query.length,
          "app.result_count" => Array(payload[:stations] || payload["stations"]).size,
          "app.batch_size" => Array(payload[:stations] || payload["stations"]).size
        )
        cache_private!
        render json: payload
      end

      def nearest
        lat = params.require(:lat)
        lon = params.require(:lon)
        payload = ApiResponseCache.fetch_map_nearest(lat, lon) do
          location = NearbyStations.nearest_to(lat, lon)
          if location
            { station: search_payload(location), status: :ok }
          else
            { station: nil, status: :not_found }
          end
        end

        station = payload[:station] || payload["station"]
        status = (payload[:status] || payload["status"] || (station ? :ok : :not_found)).to_sym
        Telemetry.add_attributes(
          "app.operation" => "map.stations.nearest",
          "app.found" => station.present?,
          "app.site_number" => station&.dig(:id) || station&.dig("id"),
          "app.state" => station&.dig(:state) || station&.dig("state")
        )
        cache_private!
        render json: { station: station }, status: status
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
