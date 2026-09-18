module Nwps
  module ParameterCodes
    STAGE = "NWPS:Stage"

    LABELS = {
      STAGE => "Gage height"
    }.freeze

    MEASUREMENT_KINDS = {
      STAGE => "water_level"
    }.freeze

    module_function

    def label_for(parameter_code, fallback: nil)
      LABELS[parameter_code.to_s].presence || fallback.presence || parameter_code.to_s.presence || "Measurement"
    end

    def measurement_kind_for(parameter_code)
      MEASUREMENT_KINDS[parameter_code.to_s]
    end

    def water_level?(parameter_code)
      parameter_code.to_s == STAGE
    end

    def preference_rank(parameter_code)
      water_level?(parameter_code) ? 0 : 99
    end
  end
end
