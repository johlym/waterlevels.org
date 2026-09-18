module Usace
  module ParameterCodes
    ELEVATION = "USACE:Elev"

    LABELS = {
      ELEVATION => "Lake/reservoir elevation"
    }.freeze

    MEASUREMENT_KINDS = {
      ELEVATION => "water_level"
    }.freeze

    module_function

    def label_for(parameter_code, fallback: nil)
      LABELS[parameter_code.to_s].presence || fallback.presence || parameter_code.to_s.presence || "Measurement"
    end

    def measurement_kind_for(parameter_code)
      MEASUREMENT_KINDS[parameter_code.to_s]
    end

    def water_level?(parameter_code)
      parameter_code.to_s == ELEVATION
    end

    def preference_rank(parameter_code)
      water_level?(parameter_code) ? 0 : 99
    end
  end
end
