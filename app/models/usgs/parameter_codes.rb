module Usgs
  module ParameterCodes
    DISCHARGE = "00060"
    TEMPERATURE = "00010"
    WATER_LEVEL_PREFERENCE = %w[62615 62614 00062 00065].freeze
    ALL = ([DISCHARGE, TEMPERATURE] + WATER_LEVEL_PREFERENCE).freeze

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
  end
end
