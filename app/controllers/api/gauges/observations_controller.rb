module Api
  module Gauges
    class ObservationsController < Api::BaseController
      def index
        location = MonitoringLocation.find_by!(site_number: params[:gauge_id])
        parameter_code = params[:parameter_code].presence
        kind = params[:kind].presence
        if parameter_code.blank? && kind.blank?
          preferred = location.time_series.selected
            .min_by { |s| [ kind_order(s.measurement_kind), Usgs::ParameterCodes.preference_rank(s.parameter_code) ] }
          parameter_code = preferred&.parameter_code
          kind = preferred&.measurement_kind || location.measurement_kinds.first
        end
        range = params[:range].presence || "7d"
        range = "7d" unless HydrographSeries::RANGES.key?(range)

        payload = ApiResponseCache.fetch_observations(
          site_number: location.site_number,
          parameter_code: parameter_code,
          kind: kind,
          range: range
        ) do
          HydrographSeries.for(location: location, kind: kind, parameter_code: parameter_code, range: range)
        end

        Telemetry.add_attributes(
          "app.site_number" => location.site_number,
          "app.state" => location.state_code,
          "app.parameter_code" => parameter_code,
          "app.measurement_kind" => kind,
          "app.range" => range,
          "app.observation_count" => Array(payload[:points] || payload["points"]).size
        )
        cache_private!
        render json: payload
      end

      private

      def kind_order(kind)
        { "water_level" => 0, "discharge" => 1, "temperature" => 2 }[kind] || 9
      end
    end
  end
end
