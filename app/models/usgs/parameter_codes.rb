module Usgs
  module ParameterCodes
    DISCHARGE = "00060"
    TEMPERATURE = "00010"
    # Prefer gage height for map/default display; elevation datums remain available as tabs.
    WATER_LEVEL_PREFERENCE = %w[00065 00062 62615 62614].freeze
    ALL = ([ DISCHARGE, TEMPERATURE ] + WATER_LEVEL_PREFERENCE).freeze

    LABELS = {
      "00065" => "Gage height",
      "00062" => "Height above datum",
      "62615" => "Elevation (NAVD 1988)",
      "62614" => "Elevation (NGVD 1929)",
      DISCHARGE => "Flow",
      TEMPERATURE => "Temperature"
    }.freeze

    module_function

    def measurement_kind_for(parameter_code)
      case parameter_code.to_s
      when DISCHARGE then "discharge"
      when TEMPERATURE then "temperature"
      when *WATER_LEVEL_PREFERENCE then "water_level"
      end
    end

    def water_level?(parameter_code)
      WATER_LEVEL_PREFERENCE.include?(parameter_code.to_s)
    end

    def preference_rank(parameter_code)
      WATER_LEVEL_PREFERENCE.index(parameter_code.to_s) || 99
    end

    def label_for(parameter_code, fallback: nil)
      code = parameter_code.to_s
      LABELS[code].presence || fallback.presence || code.presence || "Measurement"
    end
  end
end
